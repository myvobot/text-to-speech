package com.getcapacitor.community.tts;

import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.media.MediaPlayer;
import android.os.Build;
import android.os.Bundle;
import android.speech.tts.UtteranceProgressListener;
import android.speech.tts.Voice;
import android.util.Log;
import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import java.io.File;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.LinkedBlockingQueue;

public class TextToSpeech implements android.speech.tts.TextToSpeech.OnInitListener {

    public static final String LOG_TAG = "TextToSpeech";

    private Context context;
    private android.speech.tts.TextToSpeech tts = null;
    private int initializationStatus;
    private JSObject[] supportedVoices = null;
    private Map<String, SpeakResultCallback> requests = new HashMap();
    private MediaPlayer mediaPlayer;
    private LinkedBlockingQueue<TTSRequest> ttsQueue = new LinkedBlockingQueue<>();
    private boolean isPlaying = false;
    private AudioManager audioManager;
    private AudioFocusRequest currentFocusRequest;

    private class TTSRequest {

        String text;
        String utteranceId;
        int audioChannel;
        boolean forceSpeaker;
        float volume;
        SpeakResultCallback callback;

        TTSRequest(String text, String utteranceId, int audioChannel, boolean forceSpeaker, float volume, SpeakResultCallback callback) {
            this.text = text;
            this.utteranceId = utteranceId;
            this.audioChannel = audioChannel;
            this.forceSpeaker = forceSpeaker;
            this.volume = volume;
            this.callback = callback;
        }
    }

    TextToSpeech(Context context) {
        this.context = context;
        this.audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        try {
            tts = new android.speech.tts.TextToSpeech(context, this);
            tts.setOnUtteranceProgressListener(
                new UtteranceProgressListener() {
                    @Override
                    public void onStart(String utteranceId) {}

                    @Override
                    public void onDone(String utteranceId) {
                        SpeakResultCallback callback = requests.get(utteranceId);
                        if (callback != null) {
                            callback.onDone();
                            requests.remove(utteranceId);
                        }
                    }

                    @Override
                    public void onError(String utteranceId) {
                        SpeakResultCallback callback = requests.get(utteranceId);
                        if (callback != null) {
                            callback.onError();
                            requests.remove(utteranceId);
                        }
                    }

                    @Override
                    public void onRangeStart(String utteranceId, int start, int end, int frame) {
                        SpeakResultCallback callback = requests.get(utteranceId);
                        if (callback != null) {
                            callback.onRangeStart(start, end);
                        }
                    }
                }
            );
        } catch (Exception ex) {
            Log.d(LOG_TAG, ex.getLocalizedMessage());
        }
    }

    @Override
    public void onInit(int status) {
        this.initializationStatus = status;
    }

    public void speak(
        String text,
        String lang,
        float rate,
        float pitch,
        float volume,
        int voice,
        int audioChannel,
        String callbackId,
        SpeakResultCallback resultCallback,
        int queueStrategy,
        boolean forceSpeaker
    ) {
        if (queueStrategy != android.speech.tts.TextToSpeech.QUEUE_ADD) {
            stop();
        }

        // 设置语言等基本参数
        Locale locale = Locale.forLanguageTag(lang);
        tts.setLanguage(locale);
        tts.setSpeechRate(rate);
        tts.setPitch(pitch);

        // 创建临时文件
        File outputFile = new File(context.getCacheDir(), callbackId + ".wav");

        Bundle params = new Bundle();
        params.putString(android.speech.tts.TextToSpeech.Engine.KEY_PARAM_UTTERANCE_ID, callbackId);
        params.putFloat(android.speech.tts.TextToSpeech.Engine.KEY_PARAM_VOLUME, volume);

        // 设置合成完成的监听器
        tts.setOnUtteranceProgressListener(
            new UtteranceProgressListener() {
                @Override
                public void onStart(String utteranceId) {}

                @Override
                public void onDone(String utteranceId) {
                    TTSRequest request = new TTSRequest(text, utteranceId, audioChannel, forceSpeaker, volume, resultCallback);
                    ttsQueue.offer(request);

                    if (!isPlaying) {
                        playNext();
                    }
                }

                @Override
                public void onError(String utteranceId) {
                    if (resultCallback != null) {
                        resultCallback.onError();
                    }
                }

                @Override
                public void onRangeStart(String utteranceId, int start, int end, int frame) {}
            }
        );

        int result = tts.synthesizeToFile(text, params, outputFile, callbackId);
        if (result != android.speech.tts.TextToSpeech.SUCCESS) {
            if (resultCallback != null) {
                resultCallback.onError();
            }
        }
    }

    private void setupAudioSession(boolean forceSpeaker, AudioAttributes audioAttributes) {
        if (forceSpeaker) {
            audioManager.setMode(AudioManager.MODE_IN_COMMUNICATION);
            audioManager.setSpeakerphoneOn(true);
        } else {
            audioManager.setMode(AudioManager.MODE_NORMAL);
            audioManager.setSpeakerphoneOn(false);
        }

        // 请求音频焦点
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // 如果存在之前的请求，先放弃它
            if (currentFocusRequest != null) {
                audioManager.abandonAudioFocusRequest(currentFocusRequest);
            }

            currentFocusRequest =
                new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                    .setAudioAttributes(audioAttributes)
                    .setOnAudioFocusChangeListener(
                        focusChange -> {
                            if (focusChange == AudioManager.AUDIOFOCUS_LOSS) {
                                stop();
                            }
                        }
                    )
                    .build();
            audioManager.requestAudioFocus(currentFocusRequest);
        } else {
            audioManager.requestAudioFocus(null, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK);
        }
    }

    public void setAudioRoute(boolean forceSpeaker) {
        try {
            AudioManager audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);

            if (forceSpeaker) {
                audioManager.setMode(AudioManager.MODE_IN_COMMUNICATION);
                audioManager.setSpeakerphoneOn(true);
            } else {
                audioManager.setMode(AudioManager.MODE_NORMAL);
                audioManager.setSpeakerphoneOn(false);
            }
        } catch (Exception e) {
            // call.reject("Failed to set audio route: " + e.getMessage());
            Log.e(LOG_TAG, "Failed to set audio route: " + e.getMessage());
        }
    }

    private void playNext() {
        if (ttsQueue.isEmpty()) {
            isPlaying = false;
            return;
        }

        isPlaying = true;
        TTSRequest request = ttsQueue.poll();
        File audioFile = new File(context.getCacheDir(), request.utteranceId + ".wav");

        try {
            if (!audioFile.exists()) {
                Log.e(LOG_TAG, "Audio file not found: " + audioFile.getPath());
                if (request.callback != null) {
                    request.callback.onError();
                }
                playNext();
                return;
            }

            if (mediaPlayer != null) {
                mediaPlayer.release();
            }
            mediaPlayer = new MediaPlayer();
            mediaPlayer.setDataSource(audioFile.getPath());

            // 设置音频属性
            AudioAttributes audioAttributes = new AudioAttributes.Builder()
                .setUsage(request.forceSpeaker ? AudioAttributes.USAGE_VOICE_COMMUNICATION : AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build();
            mediaPlayer.setAudioAttributes(audioAttributes);

            // 设置音频会话
            setupAudioSession(request.forceSpeaker, audioAttributes);

            // 设置音量和左右声道
            float leftVolume = request.volume;
            float rightVolume = request.volume;
            switch (request.audioChannel) {
                case 1: // 左声道
                    rightVolume = 0.0f;
                    break;
                case 2: // 右声道
                    leftVolume = 0.0f;
                    break;
                default: // 双声道
                    // 保持左右声道为 request.volume
                    break;
            }
            mediaPlayer.setVolume(leftVolume, rightVolume);

            mediaPlayer.setOnCompletionListener(
                mp -> {
                    audioFile.delete();
                    // 释放音频焦点
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && currentFocusRequest != null) {
                        audioManager.abandonAudioFocusRequest(currentFocusRequest);
                        currentFocusRequest = null;
                    } else {
                        audioManager.abandonAudioFocus(null);
                    }
                    if (request.callback != null) {
                        request.callback.onDone();
                    }
                    playNext();
                }
            );

            mediaPlayer.setOnErrorListener(
                (mp, what, extra) -> {
                    Log.e(LOG_TAG, "MediaPlayer error: " + what + ", " + extra);
                    audioFile.delete();
                    if (request.callback != null) {
                        request.callback.onError();
                    }
                    playNext();
                    return true;
                }
            );

            mediaPlayer.prepare();
            mediaPlayer.start();
        } catch (Exception e) {
            Log.e(LOG_TAG, "Error playing audio: " + e.getMessage());
            audioFile.delete();
            if (request.callback != null) {
                request.callback.onError();
            }
            playNext();
        }
    }

    public void stop() {
        if (mediaPlayer != null) {
            mediaPlayer.stop();
            mediaPlayer.release();
            mediaPlayer = null;
        }
        ttsQueue.clear();
        isPlaying = false;

        // 释放音频焦点
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && currentFocusRequest != null) {
            audioManager.abandonAudioFocusRequest(currentFocusRequest);
            currentFocusRequest = null;
        } else {
            audioManager.abandonAudioFocus(null);
        }

        // 清理缓存文件
        File cacheDir = context.getCacheDir();
        File[] files = cacheDir.listFiles((dir, name) -> name.endsWith(".wav"));
        if (files != null) {
            for (File file : files) {
                file.delete();
            }
        }
    }

    public JSArray getSupportedLanguages() {
        ArrayList<String> languages = new ArrayList<>();
        Set<Locale> supportedLocales = tts.getAvailableLanguages();
        for (Locale supportedLocale : supportedLocales) {
            String tag = supportedLocale.toLanguageTag();
            languages.add(tag);
        }
        JSArray result = JSArray.from(languages.toArray());
        return result;
    }

    /**
     * @return Ordered list of voices. The order is guaranteed to remain the same as long as the voices in tts.getVoices() do not change.
     */
    public ArrayList<Voice> getSupportedVoicesOrdered() {
        Set<Voice> supportedVoices = tts.getVoices();
        ArrayList<Voice> orderedVoices = new ArrayList<Voice>();
        for (Voice supportedVoice : supportedVoices) {
            orderedVoices.add(supportedVoice);
        }

        //voice.getName() is guaranteed to be unique, so will be used for sorting.
        Collections.sort(orderedVoices, (v1, v2) -> v1.getName().compareTo(v2.getName()));

        return orderedVoices;
    }

    public JSArray getSupportedVoices() {
        ArrayList<JSObject> voices = new ArrayList<>();
        ArrayList<Voice> supportedVoices = getSupportedVoicesOrdered();
        for (Voice supportedVoice : supportedVoices) {
            JSObject obj = this.convertVoiceToJSObject(supportedVoice);
            voices.add(obj);
        }
        JSArray result = JSArray.from(voices.toArray());
        return result;
    }

    public void openInstall() {
        PackageManager packageManager = context.getPackageManager();
        Intent installIntent = new Intent();
        installIntent.setAction(android.speech.tts.TextToSpeech.Engine.ACTION_CHECK_TTS_DATA);

        ResolveInfo resolveInfo = packageManager.resolveActivity(installIntent, PackageManager.MATCH_DEFAULT_ONLY);

        if (resolveInfo != null) {
            installIntent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            context.startActivity(installIntent);
        }
    }

    public boolean isAvailable() {
        if (tts != null && initializationStatus == android.speech.tts.TextToSpeech.SUCCESS) {
            return true;
        }
        return false;
    }

    public boolean isLanguageSupported(String lang) {
        Locale locale = Locale.forLanguageTag(lang);
        int result = tts.isLanguageAvailable(locale);
        return result == tts.LANG_AVAILABLE || result == tts.LANG_COUNTRY_AVAILABLE || result == tts.LANG_COUNTRY_VAR_AVAILABLE;
    }

    public void onDestroy() {
        stop();
        if (tts != null) {
            tts.shutdown();
        }
    }

    private JSObject convertVoiceToJSObject(Voice voice) {
        Locale locale = voice.getLocale();
        JSObject obj = new JSObject();
        obj.put("voiceURI", voice.getName());
        obj.put("name", locale.getDisplayLanguage() + " " + locale.getDisplayCountry());
        obj.put("lang", locale.toLanguageTag());
        obj.put("localService", !voice.isNetworkConnectionRequired());
        obj.put("default", false);
        return obj;
    }

    public JSArray getConnectedAudioDevices() {
        JSArray devices = new JSArray();

        try {
            // 检查扬声器状态
            if (audioManager.isSpeakerphoneOn()) {
                JSObject speaker = new JSObject();
                speaker.put("name", "Speaker");
                speaker.put("type", "builtin_speaker");
                speaker.put("uid", "speaker_default");
                speaker.put("category", "speaker");
                devices.put(speaker);
            }

            // 检查有线耳机状态
            if (audioManager.isWiredHeadsetOn()) {
                JSObject wired = new JSObject();
                wired.put("name", "Wired Headset");
                wired.put("type", "wired_headset");
                wired.put("uid", "wired_default");
                wired.put("category", "wired");
                devices.put(wired);
            }

            // 获取蓝牙设备
            Object[] audioDevices = (Object[]) audioManager
                .getClass()
                .getMethod("getDevices", int.class)
                .invoke(audioManager, AudioManager.GET_DEVICES_OUTPUTS);

            if (audioDevices != null) {
                for (Object device : audioDevices) {
                    Class<?> deviceClass = device.getClass();
                    int type = (int) deviceClass.getMethod("getType").invoke(device);

                    if (type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP || type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO) {
                        String address = (String) deviceClass.getMethod("getAddress").invoke(device);
                        if (address != null && !address.equals("00:00:00:00:00:00") && !address.isEmpty()) {
                            JSObject bluetooth = new JSObject();
                            bluetooth.put("name", deviceClass.getMethod("getProductName").invoke(device));
                            bluetooth.put("type", "bluetooth_a2dp");
                            bluetooth.put("uid", address);
                            bluetooth.put("category", "bluetooth");
                            devices.put(bluetooth);
                        }
                    }
                }
            }

            // 如果没有检测到设备，返回默认接收器
            if (devices.length() == 0) {
                JSObject receiver = new JSObject();
                receiver.put("name", "Phone");
                receiver.put("type", "builtin_receiver");
                receiver.put("uid", "receiver_default");
                receiver.put("category", "receiver");
                devices.put(receiver);
            }
        } catch (Exception e) {
            Log.e("TextToSpeech", "Error getting audio devices: " + e.getMessage());
        }

        return devices;
    }
}

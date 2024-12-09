import AVFoundation
import Capacitor

enum QUEUE_STRATEGY: Int {
    case QUEUE_ADD = 1, QUEUE_FLUSH = 0
}

@objc public class TextToSpeech: NSObject, AVSpeechSynthesizerDelegate {
    let synthesizer = AVSpeechSynthesizer()
    var calls: [CAPPluginCall] = []
    let queue = DispatchQueue(label: "backgroundAudioSetup", qos: .userInitiated, attributes: [], autoreleaseFrequency: .inherit, target: nil)
    let audioEngine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()
    var audioFile: AVAudioFile?
    var audioQueue: [(URL, Int)] = []  // 存储待播放的音频文件和对应的声道
    var isPlaying = false

    override init() {
        super.init()
        self.synthesizer.delegate = self
    }

    private func setupAudioSession(forceSpeaker: Bool) throws {
        let avAudioSessionCategory: AVAudioSession.Category
        var options: AVAudioSession.CategoryOptions = [.duckOthers]

        if forceSpeaker {
            avAudioSessionCategory = .playAndRecord
            options.insert(.defaultToSpeaker)
        } else {
            avAudioSessionCategory = .playback
            options.insert(.allowBluetooth)
            options.insert(.allowBluetoothA2DP)
            options.insert(.allowAirPlay)
        }

        try AVAudioSession.sharedInstance().setCategory(avAudioSessionCategory, mode: .default, options: options)
        try AVAudioSession.sharedInstance().setActive(true)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        self.resolveCurrentCall()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        self.resolveCurrentCall()
    }

    @objc public func speak(_ text: String, _ lang: String, _ rate: Float, _ pitch: Float, _ category: String, _ volume: Float, _ voice: Int, _ queueStrategy: Int, _ forceSpeaker: Bool, _ audioChannel: Int, _ call: CAPPluginCall) throws {
        print("speak: \(text), lang: \(lang)")
        if queueStrategy == QUEUE_STRATEGY.QUEUE_FLUSH.rawValue {
            self.synthesizer.stopSpeaking(at: .immediate)
        }
        self.calls.append(call)
        
        // 设置音频会话
        do {
            try setupAudioSession(forceSpeaker: forceSpeaker)
        } catch {
            print("Error setting up AVAudioSession: \(error)")
        }
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: lang)
        utterance.rate = adjustRate(rate)
        utterance.pitchMultiplier = pitch
        utterance.volume = volume
        
        if voice >= 0 {
            let allVoices = AVSpeechSynthesisVoice.speechVoices()
            if voice < allVoices.count {
                utterance.voice = allVoices[voice]
            }
        }
        
        // 创建临时文件路径
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString + ".caf")
        
        // 使用 write 方法将音频写入文件
        synthesizer.write(utterance) { buffer in
            guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                return
            }
            
            if pcmBuffer.frameLength == 0 {
                // 音频合成完成,开始播放
                print("合成完成,开始播放, tempFile: \(tempFile)")
                self.playAudioFile(tempFile, audioChannel: audioChannel)
            } else {
                // 将 buffer 写入文件
                if self.audioFile == nil {
                    self.audioFile = try? AVAudioFile(
                        forWriting: tempFile,
                        settings: pcmBuffer.format.settings
                    )
                }
                try? self.audioFile?.write(from: pcmBuffer)
            }
        }
    }

private func playAudioFile(_ fileURL: URL, audioChannel: Int) {
    // 如果正在播放，将新的音频添加到队列
    print("isPlaying: \(isPlaying)")
    print("audioQueue: \(!audioQueue.isEmpty)")
    if isPlaying {
        audioQueue.append((fileURL, audioChannel))
        return
    }
    
    isPlaying = true
    guard let file = try? AVAudioFile(forReading: fileURL) else {
        print("playAudioFile: 文件读取失败")
        isPlaying = false
        playNextInQueue()
        return
    }
    
    audioFile = nil
    // 设置基本格式和节点   
    audioEngine.attach(playerNode)
    let format = file.processingFormat
    let stereoFormat = AVAudioFormat(
        standardFormatWithSampleRate: format.sampleRate,
        channels: 2
    )
    
    // 只使用一个混音器
    let mixer = AVAudioMixerNode()
    audioEngine.attach(mixer)
    
    // 简化连接
    audioEngine.connect(playerNode, to: mixer, format: stereoFormat)
    audioEngine.connect(mixer, to: audioEngine.mainMixerNode, format: stereoFormat)
    
    // 添加播放完成的处理
    playerNode.scheduleFile(file, at: nil) {
        DispatchQueue.main.async {
            print("playAudioFile: 播放完成, 开始下一个")
            self.isPlaying = false
            try? FileManager.default.removeItem(at: fileURL) // 清理临时文件
            self.playNextInQueue()
        }
    }
    
    do {
        try audioEngine.start()
        
        // 直接在混音器上设置声道
        switch audioChannel {
        case 1: // 左声道
            mixer.volume = 1.0
            mixer.pan = -1.0
        case 2: // 右声道
            mixer.volume = 1.0
            mixer.pan = 1.0
        default: // 双声道
            mixer.volume = 1.0
            mixer.pan = 0.0
        }
        
        playerNode.play()
    } catch {
        print("Error playing audio file: \(error)")
        isPlaying = false
        playNextInQueue()
    }
}

    @objc public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        playerNode.stop()
        audioQueue.removeAll()
        audioFile = nil
        isPlaying = false
    }

    @objc public func getSupportedLanguages() -> [String] {
        return Array(AVSpeechSynthesisVoice.speechVoices().map {
            return $0.language
        })
    }

    @objc public func isLanguageSupported(_ lang: String) -> Bool {
        let voice = AVSpeechSynthesisVoice(language: lang)
        return voice != nil
    }

    // Adjust rate for a closer match to other platform.
    @objc private func adjustRate(_ rate: Float) -> Float {
        let baseRate: Float = AVSpeechUtteranceDefaultSpeechRate
        if rate >= 1.0 {
            return (0.1 * rate) + (baseRate - 0.1)
        }
        return rate * baseRate
    }

    @objc private func resolveCurrentCall() {
        guard let call = calls.first else {
            return
        }
        call.resolve()
        calls.removeFirst()
    }

    private func playNextInQueue() {
        guard !audioQueue.isEmpty else {
            print("playNextInQueue: 队列中没有音频")
            return
        }
        
        print("playNextInQueue: 开始播放下一个")
        let next = audioQueue.removeFirst()
        playAudioFile(next.0, audioChannel: next.1)
    }
}
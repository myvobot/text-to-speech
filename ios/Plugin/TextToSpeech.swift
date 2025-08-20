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

    public func setAudioRoute(forceSpeaker: Bool) throws {
        let avAudioSessionCategory: AVAudioSession.Category
        var options: AVAudioSession.CategoryOptions = [.duckOthers]

        if forceSpeaker {
            avAudioSessionCategory = .playAndRecord
            options.insert(.defaultToSpeaker)
        } else {
            if #available(iOS 16.0, *) {
                // avAudioSessionCategory = .playback
                avAudioSessionCategory = .playAndRecord
            } else {
                avAudioSessionCategory = .playAndRecord
            }
            options.insert(.allowBluetoothA2DP)
            options.insert(.mixWithOthers)
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
        print("speak: \(text), lang: \(lang), forceSpeaker: \(forceSpeaker)")
        if queueStrategy == QUEUE_STRATEGY.QUEUE_FLUSH.rawValue {
            self.synthesizer.stopSpeaking(at: .immediate)
        }
        self.calls.append(call)
        
        // 设置音频会话
        do {
            try setAudioRoute(forceSpeaker: forceSpeaker)
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
                        settings: pcmBuffer.format.settings,
                        commonFormat: pcmBuffer.format.commonFormat,
                        interleaved: pcmBuffer.format.isInterleaved
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

    @objc public func getConnectedAudioDevices() -> [[String: Any]] {
        var devices: [[String: Any]] = []
        let audioSession = AVAudioSession.sharedInstance()
        
        // 确保音频会话已激活，并允许蓝牙设备
        do {
            try audioSession.setCategory(.playAndRecord, options: [.allowBluetoothA2DP, .allowBluetooth])
            try audioSession.setActive(true)
            
            // 获取当前连接的输出设备
            let currentOutputs = audioSession.currentRoute.outputs
            
            // 检查当前输出中的蓝牙设备
            for output in currentOutputs {
                if [.bluetoothA2DP, .bluetoothHFP].contains(output.portType) {
                    let uid = extractMacAddress(output.uid)
                    devices.append([
                        "name": output.portName,
                        "uid": uid
                    ])
                }
            }
            
            // 获取可用的输入设备 (iOS音频API的限制，无法直接获取可用的蓝牙输出设备)
            if let availableInputs = audioSession.availableInputs {
                for input in availableInputs {
                    // 检查是否为蓝牙输入设备
                    if [.bluetoothHFP].contains(input.portType) {
                        let uid = extractMacAddress(input.uid)
                        // 如果已经添加了相同UID的设备，就跳过
                        if !devices.contains(where: { ($0["uid"] as? String) == uid }) {
                            devices.append([
                                "name": input.portName,
                                "uid": uid
                            ])
                        }
                    }
                }
            }
            
        } catch {
            print("设置音频会话失败: \(error)")
        }
        
        return devices
    }
    
    // 从iOS设备UID中提取MAC地址
    private func extractMacAddress(_ uid: String) -> String {
        if uid.isEmpty {
            return "bluetooth_default"
        }
        
        // 取第一个"-"之前的部分
        if let range = uid.range(of: "-") {
            return String(uid[..<range.lowerBound])
        }
        
        return uid
    }
}

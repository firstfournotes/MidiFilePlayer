import AudioToolbox

@objc(MidiPlayer)
class MidiPlayer: CDVPlugin {
    var musicPlayer: MusicPlayer? = nil
    var musicSequence: MusicSequence? = nil
    var longestTrackLength: Float64 = 0.0
    var longestTrackBeats: MusicTimeStamp = 0
    var setupCallbackId: String = ""
    var released: Bool = true
    var stopped: Bool = true
    var paused: Bool = false

    var processingGraph: AUGraph? = nil

    @objc(setup:)
    func setup(command: CDVInvokedUrlCommand) {
        let path = command.arguments[0] as? String ?? ""
        let programs = command.arguments[1] as? [String] ?? []
        setupCallbackId = command.callbackId

        self.commandDelegate.run(inBackground: { () -> Void in
            var pluginResult: CDVPluginResult

            if path.count > 0 && programs.count > 0 {
                let success = self.setupPlayer(path: path, withInstruments: programs)

                if success {
                    self.released = false
                    self.stopped = true
                    self.paused = false

                    pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: "success")
                    pluginResult.setKeepCallbackAs(true)
                    self.commandDelegate.send(pluginResult, callbackId: self.setupCallbackId)

                    self.playerLoop()
                } else {
                    pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR)
                    self.commandDelegate.send(pluginResult, callbackId: self.setupCallbackId)
                }
            } else {
                pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR)
                self.commandDelegate.send(pluginResult, callbackId: self.setupCallbackId)
            }
        })
    }

    @objc(play:)
    func play(command: CDVInvokedUrlCommand) {
        var pluginResult: CDVPluginResult

        guard
            let mp = self.musicPlayer,
            let _ = self.musicSequence,
            !released,
            (stopped || paused) else {
                pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR)
                self.commandDelegate.send(pluginResult, callbackId: command.callbackId)
                return
        }

        MusicPlayerStart(mp)
        stopped = false
        paused = false

        pluginResult = CDVPluginResult(status: CDVCommandStatus_OK)
        self.commandDelegate.send(pluginResult, callbackId: command.callbackId)
    }

    @objc(stop:)
    func stop(command: CDVInvokedUrlCommand) {
        var pluginResult: CDVPluginResult

        guard
            let mp = self.musicPlayer,
            let _ = self.musicSequence,
            !stopped,
            !released else {
                pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR)
                self.commandDelegate.send(pluginResult, callbackId: command.callbackId)
                return
        }

        MusicPlayerStop(mp)
        self.setTime(time: 0)
        stopped = true
        paused = false

        pluginResult = CDVPluginResult(status: CDVCommandStatus_OK)
        self.commandDelegate.send(pluginResult, callbackId: command.callbackId)
    }

    @objc(pause:)
    func pause(command: CDVInvokedUrlCommand) {
        var pluginResult: CDVPluginResult

        guard
            let mp = self.musicPlayer,
            let _ = self.musicSequence,
            !paused,
            !stopped,
            !released else {
                pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR)
                self.commandDelegate.send(pluginResult, callbackId: command.callbackId)
                return
        }

        MusicPlayerStop(mp)
        stopped = false
        paused = true

        pluginResult = CDVPluginResult(status: CDVCommandStatus_OK)
        self.commandDelegate.send(pluginResult, callbackId: command.callbackId)
    }

    @objc(getCurrentPosition:)
    func getCurrentPosition(command: CDVInvokedUrlCommand) {
        var pluginResult: CDVPluginResult

        guard
            let mp = self.musicPlayer,
            let _ = self.musicSequence,
            !released else {
                pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR)
                self.commandDelegate.send(pluginResult, callbackId: command.callbackId)
                return
        }

        var position: MusicTimeStamp = 0
        MusicPlayerGetTime(mp, &position)

        pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: "\(position)")
        self.commandDelegate.send(pluginResult, callbackId: command.callbackId)
    }

    func getTime() -> Float64 {
        guard let mp = self.musicPlayer else {
            return 0.0
        }

        var beats: MusicTimeStamp = 0
        MusicPlayerGetTime(mp, &beats)

        var time: Float64 = 0.0
        MusicSequenceGetSecondsForBeats(musicSequence!, beats, &time)

        return time
    }

    @objc(seekTo:)
    func seekTo(command: CDVInvokedUrlCommand) {
        var pluginResult: CDVPluginResult

        guard
            let timeStr = command.arguments[0] as? String,
            !released else {
                pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR)
                self.commandDelegate.send(pluginResult, callbackId: command.callbackId)
                return
        }

        var time = Float64(timeStr)
        time = time! / 1000.0
        self.setTime(time: time!)

        pluginResult = CDVPluginResult(status: CDVCommandStatus_OK)
        self.commandDelegate.send(pluginResult, callbackId: command.callbackId)
    }

    func setTime(time: Float64) {
        var beats: MusicTimeStamp = 0

        guard
            let mp = self.musicPlayer,
            let ms = self.musicSequence else {
                return
        }

        MusicSequenceGetBeatsForSeconds(ms, time, &beats)
        MusicPlayerSetTime(mp, beats)
    }

    @objc(release:)
    func release(command: CDVInvokedUrlCommand) {
        var pluginResult: CDVPluginResult

        guard
            let mp = self.musicPlayer,
            let ms = self.musicSequence,
            !released else {
                pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR)
                self.commandDelegate.send(pluginResult, callbackId: command.callbackId)
                return
        }

        if !(stopped && paused) {
            MusicPlayerStop(mp)
        }

        DisposeMusicSequence(ms)
        released = true

        pluginResult = CDVPluginResult(status: CDVCommandStatus_OK)
        self.commandDelegate.send(pluginResult, callbackId: command.callbackId)
    }

    func setupPlayer(path: String, withInstruments programs: [String]) -> Bool {
        NewMusicSequence(&self.musicSequence)
        NewMusicPlayer(&self.musicPlayer)

        guard
            let ms = self.musicSequence,
            let mp = self.musicPlayer else {
                return false
        }

        var midiFileURL: URL
        if FileManager.default.fileExists(atPath: path) {
            midiFileURL = NSURL.fileURL(withPath: path, isDirectory: false)
        } else {
            return false
        }

        MusicSequenceFileLoad(ms, midiFileURL as CFURL, MusicSequenceFileTypeID.midiType, .smf_ChannelsToTracks)
        self.setupGraph(programs: programs)
        self.assignInstrumentsToTracks(programs: programs)

        MusicPlayerSetSequence(mp, ms)
        MusicPlayerPreroll(mp)
        self.setLongestTrackLength()

        return true
    }

    func setLongestTrackLength() {
        guard let ms = self.musicSequence else {
            return
        }

        var trackCount: UInt32 = 0
        MusicSequenceGetTrackCount(ms, &trackCount)

        var longest: MusicTimeStamp = 0
        for i in 0 ..< trackCount {
            var track: MusicTrack? = nil

            MusicSequenceGetIndTrack(ms, i, &track)
            guard let t = track else { continue }

            var len: MusicTimeStamp = 0
            var sz: UInt32 = 0

            MusicTrackGetProperty(t, kSequenceTrackProperty_TrackLength, &len, &sz)
            if len > longest {
                longest = len
            }
        }

        var longestTime: Float64 = 0.0
        MusicSequenceGetSecondsForBeats(ms, MusicTimeStamp(longest), &longestTime)

        longestTrackBeats = longest
        longestTrackLength = longestTime
    }

    func playerLoop() {
        var lastStopped = stopped
        var lastPaused = paused
        var pluginResult: CDVPluginResult

        while !released {
            if stopped {
                if !lastStopped {
                    lastStopped = stopped
                    released = true
                }
            } else if paused {
                if !lastPaused {
                    lastPaused = paused

                    pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: 3)
                    pluginResult.setKeepCallbackAs(true)
                    self.commandDelegate.send(pluginResult, callbackId: setupCallbackId)
                }
            } else {
                if self.getTime() >= longestTrackLength {
                    stopped = true
                    released = true
                    lastStopped = true
                    paused = false
                    lastPaused = false

                    MusicPlayerStop(musicPlayer!)
                    self.setTime(time: 0)
                } else if lastPaused || lastStopped {
                    lastPaused = false
                    lastStopped = false

                    pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: 2)
                    pluginResult.setKeepCallbackAs(true)
                    self.commandDelegate.send(pluginResult, callbackId: setupCallbackId)
                }
            }

            Thread.sleep(forTimeInterval: 0.01)
        }

        stopped = true
        paused = false

        pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: 0)
        pluginResult.setKeepCallbackAs(true)
        self.commandDelegate.send(pluginResult, callbackId: setupCallbackId)
    }

    func setupGraph(programs: [String]) {
        NewAUGraph(&self.processingGraph)

        var samplerNodes = [AUNode?](repeating: nil, count: programs.count)
        var ioNode: AUNode = AUNode()
        var mixerNode: AUNode = AUNode()
        var samplerUnits = [AudioUnit?](repeating: nil, count: programs.count)
        var ioUnit: AudioUnit? = nil
        var mixerUnit: AudioUnit? = nil

        var cd = AudioComponentDescription()
        cd.componentManufacturer = kAudioUnitManufacturer_Apple

        //----------------------------------------
        // Add 3 Sampler unit nodes to the graph
        //----------------------------------------
        cd.componentType = kAudioUnitType_MusicDevice
        cd.componentSubType = kAudioUnitSubType_Sampler

        for i in 0 ..< programs.count {
            var node = AUNode()

            AUGraphAddNode(self.processingGraph!, &cd, &node)
            samplerNodes[i] = node
        }

        //-----------------------------------
        // Add a Mixer unit node to the graph
        //-----------------------------------
        cd.componentType = kAudioUnitType_Mixer
        cd.componentSubType = kAudioUnitSubType_MultiChannelMixer

        AUGraphAddNode(self.processingGraph!, &cd, &mixerNode)

        //--------------------------------------
        // Add the Output unit node to the graph
        //--------------------------------------
        cd.componentType = kAudioUnitType_Output
        cd.componentSubType = kAudioUnitSubType_RemoteIO

        AUGraphAddNode(self.processingGraph!, &cd, &ioNode)

        //---------------
        // Open the graph
        //---------------
        AUGraphOpen(self.processingGraph!)

        //-----------------------------------------------------------
        // Obtain the mixer unit instance from its corresponding node
        //-----------------------------------------------------------
        AUGraphNodeInfo(self.processingGraph!, mixerNode, nil, &mixerUnit)

        //--------------------------------
        // Set the bus count for the mixer
        //--------------------------------
        var numBuses = 3
        AudioUnitSetProperty(mixerUnit!, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &numBuses, UInt32(MemoryLayout.size(ofValue: numBuses)))

        // set volume
//        for i in 0 ..< numBuses {
//            let volume: AudioUnitParameterValue = 0.0
//            AudioUnitSetParameter(mixerUnit!, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, AudioUnitElement(i), volume, 0)
//        }

        //------------------
        // Connect the nodes
        //------------------
        for i in 0 ..< programs.count {
            AUGraphConnectNodeInput(self.processingGraph!, samplerNodes[i]!, 0, mixerNode, UInt32(i))
        }

        // Connect the mixer unit to the output unit
        AUGraphConnectNodeInput(self.processingGraph!, mixerNode, 0, ioNode, 0)

        //----------------------------------------
        // Set the samplerUnits to the instruments
        //----------------------------------------
        // Obtain references to all of the audio units from their nodes
        for i in 0 ..< programs.count {
            AUGraphNodeInfo(self.processingGraph!, samplerNodes[i]!, nil, &samplerUnits[i])
        }

        // Get sound fonts URL
        guard
            let bankURL = Bundle.main.url(forResource: "sounds", withExtension: "sf2"),
            FileManager.default.fileExists(atPath: bankURL.path) else {
                return
        }

        // Set instruments
        for i in 0 ..< programs.count {
            var bpdata = AUSamplerBankPresetData(
                bankURL: Unmanaged<CFURL>.passUnretained(bankURL as CFURL),
                bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                bankLSB: UInt8(kAUSampler_DefaultBankLSB),
                presetID: UInt8(programs[i])!,
                reserved: UInt8(0)
            )
            AudioUnitSetProperty(samplerUnits[i]!, kAUSamplerProperty_LoadPresetFromBank, kAudioUnitScope_Global, 0, &bpdata, UInt32(MemoryLayout.size(ofValue: bpdata)))
        }

        //--------------------------------------------------------
        // Obtain the io unit instance from its corresponding node
        //--------------------------------------------------------
        AUGraphNodeInfo(self.processingGraph!, ioNode, nil, &ioUnit)

        //-------------------------------------
        // Set the sequencer to ths audio graph
        //-------------------------------------
        MusicSequenceSetAUGraph(musicSequence!, self.processingGraph)
    }

    func assignInstrumentsToTracks(programs: [String]) {
        var tracks = [MusicTrack?](repeating: nil, count: programs.count)

        for i in 0 ..< programs.count {
            var track: MusicTrack?

            MusicSequenceGetIndTrack(musicSequence!, UInt32(i), &track)
            tracks[i] = track
        }

        var nodes = [AUNode?](repeating: nil, count: programs.count)

        for i in 0 ..< programs.count {
            var node = AUNode()
            AUGraphGetIndNode(self.processingGraph!, UInt32(i), &node)
            nodes[i] = node
        }

        for i in 0 ..< programs.count {
            if let track = tracks[i], let node = nodes[i] {
                MusicTrackSetDestNode(track, node)
            }
        }
    }
}

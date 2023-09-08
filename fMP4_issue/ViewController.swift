//
//  ViewController.swift
//  fMP4_issue
//
//  Created by Steven Chen on 2023/9/8.
//

import UIKit
import AVKit
import AVFoundation

class ViewController: UIViewController {

    @IBOutlet var playerView: VideoView!

    override func viewDidLoad() {
        super.viewDidLoad()

        let urls = [
//            ["name": "h264", "type" : "mp4"],
            ["name": "h264_fragmented", "type" : "mp4"],
        ].compactMap({ videoMeta -> URL? in
            if let path = Bundle.main.path(forResource: videoMeta["name"], ofType: videoMeta["type"]) {
                let fileUrl = URL(fileURLWithPath: path)
                let rtcUrl = URL(string: fileUrl.absoluteString.replacingOccurrences(of: "file:", with: "rtc:"))
                return rtcUrl
            }
            return nil
        })

        playerView.dataSource = self
        playerView.setPlaylist(urls)
        playerView.player?.play()
    }

    private func readContent(_ url: URL?) -> Data? {
        guard let url = url else {
            return nil
        }

        let fileUrl = URL(string: url.absoluteString.replacingOccurrences(of: "rtc:", with: "file:"))
        do {
            if let fileUrl = fileUrl {
                let rawData: Data = try Data(contentsOf: fileUrl)
                return rawData
            }
        } catch {
            print(error)
        }

        return nil
    }
}

protocol AVDataSource {
    func read(_ url: URL?, _ offset: Int64, _ length: Int64) -> Data?
    func getContentLength(url: URL?) -> Int64
}

extension ViewController : AVDataSource {
    func read(_ url: URL?, _ offset: Int64, _ length: Int64) -> Data? {
        if let content = readContent(url) {
            return content[offset...(offset + length - 1)]
        }
        return nil
    }

    func getContentLength(url: URL?) -> Int64 {
        return Int64(readContent(url)?.count ?? 0)
    }
}

class VideoView: UIView {
    private let customDispathQueue = DispatchQueue(label: "resource_loader")

    var dataSource: AVDataSource?
    var avResourceLoadler: AVResourceLoader?
    private var timeObserver: Any?
    private var playerItemContext = 0

    private var playerLayer: AVPlayerLayer {
        return layer as! AVPlayerLayer
    }

    var player: AVQueuePlayer? {
        get {
            return playerLayer.player as? AVQueuePlayer
        }
        set {
            playerLayer.player = newValue
        }
    }

    override class var layerClass: AnyClass {
        return AVPlayerLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        doInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        doInit()
    }

    private func doInit() {
        self.playerLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
    }

    func setPlaylist(_ urls: [URL?]) {
        avResourceLoadler = AVResourceLoader(dataSource: dataSource)

        let avPlayerItems = urls.compactMap { url -> AVPlayerItem? in
            createCustomSchemeAvPlayerItem(url)
        }

        self.player = AVQueuePlayer(items: avPlayerItems)
        self.player?.automaticallyWaitsToMinimizeStalling = false
        setupPlayerObserver()
    }

    private func setupPlayerObserver() {
        guard let player = player else { return }

        // Observe player state
        player.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.status), options: [.old, .new], context: &playerItemContext)
        player.addObserver(self, forKeyPath: #keyPath(AVPlayer.rate), options: [.old, .new], context: &playerItemContext)
        player.addObserver(self, forKeyPath: #keyPath(AVPlayer.timeControlStatus), options: [.old, .new], context: &playerItemContext)

        // Observer current playback position
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC)),
            queue: .main, using: { [weak self] _ in

                if player.currentItem?.status == .readyToPlay,
                   player.rate != 0,
                   self?.playerLayer.isReadyForDisplay == true {
                    NSLog("Playing")
                } else {
                    NSLog("Not playing")
                }
                if player.currentItem?.isPlaybackBufferEmpty ?? false {
                    NSLog("isPlaybackBufferEmpty")
                }
                if player.currentItem?.isPlaybackBufferFull ?? false {
                    NSLog("isPlaybackBufferFull")
                }
                if player.currentItem?.isPlaybackLikelyToKeepUp ?? false {
                    NSLog("isPlaybackLikelyToKeepUp")
                }
            })
    }

    // MARK: KVO
    // swiftlint:disable:next block_based_kvo
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard context == &playerItemContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }

        var url: URL?
        if let playerItem = object as? AVPlayerItem {
            if let error = playerItem.error {
//                print("PlayerStatus playerItem \(error)" )
            }
            url = (playerItem.asset as? AVURLAsset)?.url
        }

//        print("PlayerStatus observeValue keyPath= \(String(describing: keyPath))" )
        if keyPath == #keyPath(AVPlayerItem.status) {
            let status: AVPlayerItem.Status
            if let statusNumber = change?[.newKey] as? NSNumber {
                status = AVPlayerItem.Status(rawValue: statusNumber.intValue)!
            } else {
                status = .unknown
            }
        } else if keyPath == #keyPath(AVPlayer.rate) {
            let rate: Int
            if let rateNumber = change?[.newKey] as? NSNumber {
                rate = rateNumber.intValue
            } else {
                rate = 0
            }
        } else if keyPath == #keyPath(AVPlayer.timeControlStatus) {
            guard let player = object as? AVQueuePlayer else { return }
            if let reason = player.reasonForWaitingToPlay, reason.debugDescription != "unknown" {
                NSLog("reason : \(reason.debugDescription), \(player.timeControlStatus.rawValue)")
            }
        }
    }

    /**
     * Implementations
     */
    private func createCustomSchemeAvPlayerItem(_ url: URL?) -> AVPlayerItem? {
        if let url = url {
            let avAsset = AVURLAsset(url: url)

            if url.scheme?.hasPrefix("rtc") == true {
                avAsset.resourceLoader.setDelegate(avResourceLoadler, queue: customDispathQueue)
            }

            return AVPlayerItem(asset: avAsset)
        }

        return nil
    }
}

class AVResourceLoader: NSObject {
    private var dataSource: AVDataSource? = nil
    let customDispatchQueue = DispatchQueue(label: "resource_loader")
    private var index = 0

    init(dataSource: AVDataSource?) {
        self.dataSource = dataSource
    }

    private func readContent(_ url: URL?) -> Data? {
        guard let url = url else {
            return nil
        }

        let fileUrl = URL(string: url.absoluteString.replacingOccurrences(of: "rtc:", with: "file:"))
        do {
            if let fileUrl = fileUrl {
                let rawData: Data = try Data(contentsOf: fileUrl)
                return rawData
            }
        } catch {
            print(error)
        }

        return nil
    }
}

extension AVResourceLoader : AVAssetResourceLoaderDelegate {

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {

        if loadingRequest.isCancelled {
            return false
        }

        let url = loadingRequest.request.url

        // fetch meta data
        if let _ = loadingRequest.contentInformationRequest {
            loadingRequest.contentInformationRequest?.contentLength = dataSource?.getContentLength(url: url) ?? 0
            NSLog("content length \((dataSource?.getContentLength(url: url) ?? 0)) bytes")
            loadingRequest.contentInformationRequest?.contentType = "video/mp4"
            loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = true

            if let url = url, let content = dataSource?.read(url, Int64(0), 2) {
                loadingRequest.dataRequest?.respond(with: content)
            }

            loadingRequest.finishLoading()
            return true
        }

        // fetch content
        let offset = loadingRequest.dataRequest?.currentOffset ?? 0
        let length = Int64(loadingRequest.dataRequest?.requestedLength ?? 1)
        let lengthReduce = min(length, 128 * 1000) // Data channel max transfer size

        NSLog("Request \(length) bytes with offset \(offset) bytes")

        if let url = url, let content = dataSource?.read(url, Int64(offset), lengthReduce) {

            customDispatchQueue.async {
                usleep(200_000)
                if loadingRequest.isCancelled {
                    NSLog("Canceled")
                    return
                }
                NSLog("filled \(content.count) bytes")
                loadingRequest.dataRequest?.respond(with: content)
                loadingRequest.finishLoading()
            }
            return true
        }

        return false
    }
}

extension AVPlayer.WaitingReason: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .toMinimizeStalls: return "toMinimizeStalls"
        case .evaluatingBufferingRate: return "evaluatingBufferingRate"
        case .noItemToPlay: return "noItemToPlay"
        default:
            if #available(iOS 15, *) {
                if self == .waitingForCoordinatedPlayback {
                    return "waitingForCoordinatedPlayback"
                }
            }
            return "unknown"
        }
    }
}

/**
 * Tae Won Ha - http://taewon.de - @hataewon
 * See LICENSE
 */

import Foundation
import RxMessagePort
import RxSwift

class UiBridge {

  enum Message {

    case ready

    case initVimError
    case resize(width: Int, height: Int)
    case clear
    case setMenu
    case busyStart
    case busyStop
    case mouseOn
    case mouseOff
    case modeChange(CursorModeShape)
    case setScrollRegion(top: Int, bottom: Int, left: Int, right: Int)
    case scroll(Int)
    case unmark(row: Int, column: Int)
    case bell
    case visualBell
    case flush([Data])
    case setForeground(Int)
    case setBackground(Int)
    case setSpecial(Int)
    case setTitle(String)
    case setIcon(String)
    case stop
    case dirtyStatusChanged(Bool)
    case cwdChanged(String)
    case colorSchemeChanged([Int])
    case autoCommandEvent(autocmd: NvimAutoCommandEvent, bufferHandle: Int)
    case debug1
    case unknown
  }

  enum Error: Swift.Error {

    case launchNvim
    case nvimNotReady
    case nvimQuitting
    case ipc(Swift.Error)
  }

  var stream: Observable<Message> {
    return self.streamSubject.asObservable()
  }

  let nvimQuitCondition = NSCondition()

  private(set) var isNvimQuitting = false
  private(set) var isNvimQuit = false

  init(uuid: String, config: NvimView.Config) {
    self.uuid = uuid

    self.useInteractiveZsh = config.useInteractiveZsh
    self.nvimArgs = config.nvimArgs ?? []
    self.cwd = config.cwd

    self.server.stream
      .subscribe(onNext: { message in
        self.handleMessage(msgId: message.msgid, data: message.data)
      }, onError: { error in
        self.logger.error("There wsa an error on the local message port server: \(error)")
        self.streamSubject.onError(Error.ipc(error))
      })
      .disposed(by: self.disposeBag)
  }

  func runLocalServerAndNvim(width: Int, height: Int) -> Completable {
    self.initialWidth = width
    self.initialHeight = height

    return self.server
      .run(as: self.localServerName)
      .andThen(Completable.create { completable in
        self.launchNvimUsingLoginShell()

        let deadline = Date().addingTimeInterval(timeout)
        self.nvimReadyCondition.lock()
        defer { self.nvimReadyCondition.unlock() }
        while !self.isNvimReady && self.nvimReadyCondition.wait(until: deadline) {}

        if self.isNvimReady {
          self.streamSubject.onNext(.ready)
          if self.isInitErrorPresent {
            self.streamSubject.onNext(.initVimError)
          }
          completable(.completed)
        } else {
          self.streamSubject.onError(Error.launchNvim)
          completable(.error(Error.launchNvim))
        }

        return Disposables.create()
      })
  }

  func vimInput(_ str: String) -> Completable {
    return self.sendMessage(msgId: .input, data: str.data(using: .utf8))
  }

  func vimInputMarkedText(_ markedText: String) -> Completable {
    return self.sendMessage(msgId: .inputMarked, data: markedText.data(using: .utf8))
  }

  func deleteCharacters(_ count: Int) -> Completable {
    return self.sendMessage(msgId: .delete, data: [count].data())
  }

  func resize(width: Int, height: Int) -> Completable {
    return self.sendMessage(msgId: .resize, data: [width, height].data())
  }

  func focusGained(_ gained: Bool) -> Completable {
    return self.sendMessage(msgId: .focusGained, data: [gained].data())
  }

  func scroll(horizontal: Int, vertical: Int, at position: Position) -> Completable {
    return self.sendMessage(msgId: .scroll, data: [horizontal, vertical, position.row, position.column].data())
  }

  func quit() -> Completable {
    self.isNvimQuitting = true

    let completable = self.closePorts()

    self.nvimServerProc?.waitUntilExit()

    self.nvimQuitCondition.lock()
    defer {
      self.nvimQuitCondition.signal()
      self.nvimQuitCondition.unlock()
    }
    self.isNvimQuit = true

    self.logger.info("NvimServer \(self.uuid) exited successfully.")
    return completable
  }

  func forceQuit() -> Completable {
    self.logger.info("Force-exiting NvimServer \(self.uuid).")

    self.isNvimQuitting = true

    let completable = self.closePorts()
    self.forceExitNvimServer()

    self.nvimQuitCondition.lock()
    defer {
      self.nvimQuitCondition.signal()
      self.nvimQuitCondition.unlock()
    }
    self.isNvimQuit = true

    self.logger.info("NvimServer \(self.uuid) was forcefully exited.")
    return completable
  }

  func debug() -> Completable {
    return self.sendMessage(msgId: .debug1, data: nil)
  }

  private func handleMessage(msgId: Int32, data: Data?) {
    guard let msg = NvimServerMsgId(rawValue: Int(msgId)) else {
      self.streamSubject.onNext(.unknown)
      return
    }

    switch msg {

    case .serverReady:
      self
        .establishNvimConnection()
        .subscribe(onError: { error in
          self.streamSubject.onError(Error.ipc(error))
        })
        .disposed(by: self.disposeBag)

    case .nvimReady:
      self.isInitErrorPresent = data?.asArray(ofType: Bool.self, count: 1)?[0] ?? false
      self.isNvimReady = true
      self.nvimReadyCondition.lock()
      defer {
        self.nvimReadyCondition.signal()
        self.nvimReadyCondition.unlock()
      }

    case .resize:
      guard let values = data?.asArray(ofType: Int.self, count: 2) else {
        return
      }

      self.streamSubject.onNext(.resize(width: values[0], height: values[1]))

    case .clear:
      self.streamSubject.onNext(.clear)

    case .setMenu:
      self.streamSubject.onNext(.setMenu)

    case .busyStart:
      self.streamSubject.onNext(.busyStart)

    case .busyStop:
      self.streamSubject.onNext(.busyStop)

    case .mouseOn:
      self.streamSubject.onNext(.mouseOn)

    case .mouseOff:
      self.streamSubject.onNext(.mouseOff)

    case .modeChange:
      guard let values = data?.asArray(ofType: CursorModeShape.self, count: 1) else {
        return
      }

      self.streamSubject.onNext(.modeChange(values[0]))

    case .setScrollRegion:
      guard let values = data?.asArray(ofType: Int.self, count: 4) else {
        return
      }

      self.streamSubject.onNext(.setScrollRegion(top: values[0], bottom: values[1], left: values[2], right: values[3]))

    case .scroll:
      guard let values = data?.asArray(ofType: Int.self, count: 1) else {
        return
      }

      self.streamSubject.onNext(.scroll(values[0]))

    case .unmark:
      guard let values = data?.asArray(ofType: Int.self, count: 2) else {
        return
      }

      self.streamSubject.onNext(.unmark(row: values[0], column: values[1]))

    case .bell:
      self.streamSubject.onNext(.bell)

    case .visualBell:
      self.streamSubject.onNext(.visualBell)

    case .flush:
      guard let d = data, let renderData = NSKeyedUnarchiver.unarchiveObject(with: d) as? [Data] else {
        return
      }

      self.streamSubject.onNext(.flush(renderData))

    case .setForeground:
      guard let values = data?.asArray(ofType: Int.self, count: 1) else {
        return
      }

      self.streamSubject.onNext(.setForeground(values[0]))

    case .setBackground:
      guard let values = data?.asArray(ofType: Int.self, count: 1) else {
        return
      }

      self.streamSubject.onNext(.setBackground(values[0]))

    case .setSpecial:
      guard let values = data?.asArray(ofType: Int.self, count: 1) else {
        return
      }

      self.streamSubject.onNext(.setSpecial(values[0]))

    case .setTitle:
      guard let d = data, let title = String(data: d, encoding: .utf8) else {
        return
      }

      self.streamSubject.onNext(.setTitle(title))

    case .setIcon:
      guard let d = data, let icon = String(data: d, encoding: .utf8) else {
        return
      }

      self.streamSubject.onNext(.setIcon(icon))

    case .stop:
      self.streamSubject.onNext(.stop)

    case .dirtyStatusChanged:
      guard let values = data?.asArray(ofType: Bool.self, count: 1) else {
        return
      }

      self.streamSubject.onNext(.dirtyStatusChanged(values[0]))

    case .cwdChanged:
      guard let d = data, let cwd = String(data: d, encoding: .utf8) else {
        return
      }

      self.streamSubject.onNext(.cwdChanged(cwd))


    case .colorSchemeChanged:
      guard let values = data?.asArray(ofType: Int.self, count: 5) else {
        return
      }

      self.streamSubject.onNext(.colorSchemeChanged(values))

    case .autoCommandEvent:
      if data?.count == 2 * MemoryLayout<Int>.stride {
        guard let values = data?.asArray(ofType: Int.self, count: 2),
              let cmd = NvimAutoCommandEvent(rawValue: values[0])
          else {
          return
        }

        self.streamSubject.onNext(.autoCommandEvent(autocmd: cmd, bufferHandle: values[1]))

      } else {
        guard let values = data?.asArray(ofType: NvimAutoCommandEvent.self, count: 1) else {
          return
        }

        self.streamSubject.onNext(.autoCommandEvent(autocmd: values[0], bufferHandle: -1))
      }

    case .debug1:
      self.streamSubject.onNext(.debug1)

    }
  }

  private func closePorts() -> Completable {
    return self.client
      .stop()
      .andThen(self.server.stop())
  }

  private func establishNvimConnection() -> Completable {
    return self.client
      .connect(to: self.remoteServerName)
      .andThen(self.sendMessage(msgId: .agentReady, data: [self.initialWidth, self.initialHeight].data()))
  }

  private func sendMessage(msgId: NvimBridgeMsgId, data: Data?) -> Completable {
    // .agentReady is needed to set isNvimReady
    guard self.isNvimReady || msgId == .agentReady else {
      self.logger.info("NvimServer is not ready, but trying to send msg: \(msgId.rawValue).")
      return Completable.error(Error.nvimNotReady)
    }

    if self.isNvimQuitting {
      self.logger.info("NvimServer is quitting, but trying to send msg: \(msgId.rawValue).")
      return Completable.error(Error.nvimQuitting)
    }

    return self.client
      .send(msgid: Int32(msgId.rawValue), data: data, expectsReply: false)
      .asCompletable()
  }

  private func forceExitNvimServer() {
    self.nvimServerProc?.interrupt()
    self.nvimServerProc?.terminate()
  }

  private func launchNvimUsingLoginShell() {
    let selfEnv = ProcessInfo.processInfo.environment

    let shellPath = URL(fileURLWithPath: selfEnv["SHELL"] ?? "/bin/bash")
    let shellName = shellPath.lastPathComponent
    var shellArgs = [String]()
    if shellName != "tcsh" {
      // tcsh does not like the -l option
      shellArgs.append("-l")
    }
    if self.useInteractiveZsh && shellName == "zsh" {
      shellArgs.append("-i")
    }

    let listenAddress = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vimr_\(self.uuid).sock")
    var env = selfEnv
    env["NVIM_LISTEN_ADDRESS"] = listenAddress.path

    let inputPipe = Pipe()
    let process = Process()
    process.environment = env
    process.standardInput = inputPipe
    process.currentDirectoryPath = self.cwd.path
    process.launchPath = shellPath.path
    process.arguments = shellArgs
    process.launch()

    self.nvimServerProc = process

    nvimArgs.append("--headless")
    let cmd = "exec '\(self.nvimServerExecutablePath())' '\(self.localServerName)' '\(self.remoteServerName)' "
      .appending(self.nvimArgs.map { "'\($0)'" }.joined(separator: " "))

    self.logger.debug(cmd)

    let writeHandle = inputPipe.fileHandleForWriting
    guard let cmdData = cmd.data(using: .utf8) else {
      preconditionFailure("Could not get Data from the string '\(cmd)'")
    }
    writeHandle.write(cmdData)
    writeHandle.closeFile()
  }

  private func nvimServerExecutablePath() -> String {
    guard let plugInsPath = Bundle(for: UiBridge.self).builtInPlugInsPath else {
      preconditionFailure("NvimServer not available!")
    }

    return URL(fileURLWithPath: plugInsPath).appendingPathComponent("NvimServer").path
  }

  private let logger = LogContext.fileLogger(as: UiBridge.self, with: URL(fileURLWithPath: "/tmp/nvv-bridge.log"))

  private let uuid: String

  private let useInteractiveZsh: Bool
  private let cwd: URL
  private var nvimArgs: [String]

  private let server = RxMessagePortServer()
  private let client = RxMessagePortClient()

  private var nvimServerProc: Process?

  private var isNvimReady = false
  private let nvimReadyCondition = NSCondition()
  private var isInitErrorPresent = false

  private var initialWidth = 40
  private var initialHeight = 20

  private let streamSubject = PublishSubject<Message>()
  private let disposeBag = DisposeBag()

  private var localServerName: String {
    return "com.qvacua.vimr.\(self.uuid)"
  }

  private var remoteServerName: String {
    return "com.qvacua.vimr.neovim-server.\(self.uuid)"
  }
}

private let timeout = CFTimeInterval(5)

private extension Data {

  func asArray<T>(ofType: T.Type, count: Int) -> [T]? {
    guard (self.count / MemoryLayout<T>.stride) <= count else {
      return nil
    }

    return self.withUnsafeBytes { (p: UnsafePointer<T>) in Array(UnsafeBufferPointer(start: p, count: count)) }
  }
}

private extension Array {

  func data() -> Data {
    return self.withUnsafeBytes { pointer in
      if let baseAddr = pointer.baseAddress {
        return Data(bytes: baseAddr, count: pointer.count)
      }

      let newPointer = UnsafeMutablePointer<Element>.allocate(capacity: self.count)
      for (index, element) in self.enumerated() {
        newPointer[index] = element
      }
      return Data(bytesNoCopy: newPointer, count: self.count, deallocator: .free)
    }
  }
}

//
//  HubConnection.swift
//  SignalRClient
//
//  Created by Pawel Kadluczka on 3/4/17.
//  Copyright © 2017 Pawel Kadluczka. All rights reserved.
//

import Foundation

public class HubConnection: ConnectionDelegate {

    private var invocationId: Int = 0
    private let hubConnectionQueue: DispatchQueue
    private var pendingCalls = [String: ServerInvocationHandler]()
    private var callbacks = [String: (ArgumentExtractor) throws -> Void]()
    private var handshakeHandled = false
    private let logger: Logger

    private var connection: Connection
    private var hubProtocol: HubProtocol
    public weak var delegate: HubConnectionDelegate?

    public init(connection: Connection, hubProtocol: HubProtocol, logger: Logger = NullLogger()) {
        self.connection = connection
        self.hubProtocol = hubProtocol
        self.logger = logger
        self.hubConnectionQueue = DispatchQueue(label: "SignalR.hubconnection.queue")
        self.connection.delegate = self
    }

    public func start() {
        logger.log(logLevel: .info, message: "Starting hub connection")
        connection.start()
    }

    fileprivate func connectionStarted() {
        logger.log(logLevel: .info, message: "Hub connection started")
        // TODO: support custom protcols
        // TODO: add negative test (e.g. invalid protocol)
        let handshakeRequest = HandshakeProtocol.createHandshakeRequest(hubProtocol: hubProtocol)
        logger.log(logLevel: .debug, message: "Sending handshake request: \(handshakeRequest)")
        connection.send(data: "\(handshakeRequest)".data(using: .utf8)!) { error in
            if let e = error {
                self.logger.log(logLevel: .error, message: "Sending handshake request failed: \(e)")
                delegate?.connectionDidFailToOpen(error: e)
            }
        }
    }

    public func stop() {
        logger.log(logLevel: .info, message: "Stopping hub connection")
        connection.stop(stopError: nil)
    }

    public func on(method: String, callback: @escaping (_ ArgumentExtractor: ArgumentExtractor) throws -> Void) {
        logger.log(logLevel: .info, message: "Registering client side hub method: '\(method)'")

        var callbackRegistered = false
        hubConnectionQueue.sync {
            callbackRegistered = callbacks.keys.contains(method)
            callbacks[method] = callback
        }

        if (callbackRegistered) {
            logger.log(logLevel: .warning, message: "Client side hub method '\(method)' was already registered and was overwritten")
        }
    }

    public func send(method: String, arguments:[Encodable], sendDidComplete: @escaping (_ error: Error?) -> Void) {
        logger.log(logLevel: .info, message: "Sending to server side hub method: '\(method)'")

        if !ensureConnectionStarted() {sendDidComplete($0)} {
            return
        }

        do {
            let invocationMessage = ServerInvocationMessage(target: method, arguments: arguments)
            let invocationData = try hubProtocol.writeMessage(message: invocationMessage)
            connection.send(data: invocationData, sendDidComplete: sendDidComplete)
        } catch {
            logger.log(logLevel: .error, message: "Sending to server side hub method '\(method)' failed. Error: \(error)")
            sendDidComplete(error)
        }
    }

    public func invoke(method: String, arguments: [Encodable], invocationDidComplete: @escaping (_ error: Error?) -> Void) {
        invoke(method: method, arguments: arguments, returnType: DecodableVoid.self, invocationDidComplete: {_, error in
            invocationDidComplete(error)
        })
    }

    public func invoke<T: Decodable>(method: String, arguments: [Encodable], returnType: T.Type, invocationDidComplete: @escaping (_ result: T?, _ error: Error?) -> Void) {
        logger.log(logLevel: .info, message: "Invoking server side hub method: '\(method)'")

        if !ensureConnectionStarted() {invocationDidComplete(nil, $0)} {
            return
        }

        let invocationHandler = InvocationHandler<T>(logger: logger, invocationDidComplete: invocationDidComplete)

        _ = invoke(invocationHandler: invocationHandler, method: method, arguments: arguments)
    }

    public func stream<T: Decodable>(method: String, arguments: [Encodable], itemType: T.Type, streamItemReceived: @escaping (_ item: T?) -> Void, invocationDidComplete: @escaping (_ error: Error?) -> Void) -> StreamHandle {
        logger.log(logLevel: .info, message: "Invoking server side streaming hub method: '\(method)'")

        if !ensureConnectionStarted() {invocationDidComplete($0)} {
            return StreamHandle(invocationId: "")
        }

        let streamInvocationHandler = StreamInvocationHandler<T>(logger: logger, streamItemReceived: streamItemReceived, invocationDidComplete: invocationDidComplete)

        let id = invoke(invocationHandler: streamInvocationHandler, method: method, arguments: arguments)

        return StreamHandle(invocationId: id)
    }

    public func cancelStreamInvocation(streamHandle: StreamHandle, cancelDidFail: @escaping (_ error: Error) -> Void) {
        logger.log(logLevel: .info, message: "Cancelling server side streaming hub method")

        if !ensureConnectionStarted() {cancelDidFail($0)} {
            return
        }

        if streamHandle.invocationId == "" {
            logger.log(logLevel: .error, message: "Invalid stream handle")
            cancelDidFail(SignalRError.invalidOperation(message: "Invalid stream handle."))
            return
        }

        hubConnectionQueue.sync {
            _ = pendingCalls.removeValue(forKey: streamHandle.invocationId)
        }

        let cancelInvocationMessage = CancelInvocationMessage(invocationId: streamHandle.invocationId)
        do {
            let cancelInvocationData = try hubProtocol.writeMessage(message: cancelInvocationMessage)
            connection.send(data: cancelInvocationData, sendDidComplete: {error in
                if let e = error {
                    self.logger.log(logLevel: .error, message: "Sending cancellation of server side streaming hub returned error: \(e)")
                    cancelDidFail(e)
                }
            })
        } catch {
            logger.log(logLevel: .error, message: "Sending cancellation of server side streaming hub method failed: \(error)")
            cancelDidFail(error)
        }
    }

    fileprivate func invoke(invocationHandler: ServerInvocationHandler, method: String, arguments: [Encodable]) -> String {
        logger.log(logLevel: .info, message: "Invoking server side hub method '\(method)' with \(arguments.count) argument(s)")
        var id:String = ""
        hubConnectionQueue.sync {
            invocationId = invocationId + 1
            id = "\(invocationId)"
            pendingCalls[id] = invocationHandler
        }

        do {
            let invocationMessage = invocationHandler.createInvocationMessage(invocationId: id, method: method, arguments: arguments)
            let invocationData = try hubProtocol.writeMessage(message: invocationMessage)

            connection.send(data: invocationData) { error in
                if let e = error {
                    self.logger.log(logLevel: .error, message: "Invoking server hub method \(method) returned error: \(e)")
                    failInvocationWithError(invocationHandler: invocationHandler, invocationId: id, error: e)
                }
            }
        } catch {
            logger.log(logLevel: .error, message: "Invoking server hub method \(method) failed: \(error)")
            failInvocationWithError(invocationHandler: invocationHandler, invocationId: id, error: error)
        }

        return id
    }

    private func failInvocationWithError(invocationHandler: ServerInvocationHandler, invocationId: String, error: Error) {
        hubConnectionQueue.sync {
            _ = pendingCalls.removeValue(forKey: invocationId)
        }

        Util.dispatchToMainThread {
            invocationHandler.raiseError(error: error)
        }
    }

    private func ensureConnectionStarted(errorHandler: (Error)->Void) -> Bool {
        if !handshakeHandled {
            logger.log(logLevel: .error, message: "Attempting to send data before connection has been started.")
            errorHandler(SignalRError.invalidOperation(message: "Attempting to send data before connection has been started."))
            return false
        }
        return true
    }

    private func hubConnectionDidReceiveData(data: Data) {
        logger.log(logLevel: .debug, message: "Data received")
        var data = data
        if !handshakeHandled {
            logger.log(logLevel: .debug, message: "Processing handshake response: \(String(data: data, encoding: .utf8) ?? "(invalid)")")
            let (error, remainingData) = HandshakeProtocol.parseHandshakeResponse(data: data)
            handshakeHandled = true
            data = remainingData
            if let e = error {
                logger.log(logLevel: .error, message: "Parsing handshake response failed: \(e)")
                delegate?.connectionDidFailToOpen(error: e)
                return
            }
            delegate?.connectionDidOpen(hubConnection: self)
        }
        do {
            let messages = try hubProtocol.parseMessages(input: data)
            for incomingMessage in messages {
                switch(incomingMessage.type) {
                case MessageType.Completion:
                    try handleCompletion(message: incomingMessage as! CompletionMessage)
                case MessageType.StreamItem:
                    try handleStreamItem(message: incomingMessage as! StreamItemMessage)
                case MessageType.Invocation:
                    handleInvocation(message: incomingMessage as! ClientInvocationMessage)
                case MessageType.Close:
                    connection.stop(stopError: SignalRError.serverClose(message: (incomingMessage as! CloseMessage).error))
                case MessageType.Ping:
                    // no action required for ping messages
                    break
                default:
                    logger.log(logLevel: .error, message: "Usupported message type: \(incomingMessage.type.rawValue)")
                }
            }
        } catch {
            logger.log(logLevel: .debug, message: "Parsing message failed: \(error)")
        }
    }

    private func handleCompletion(message: CompletionMessage) throws {
        var serverInvocationHandler: ServerInvocationHandler?
        self.hubConnectionQueue.sync {
            serverInvocationHandler = self.pendingCalls.removeValue(forKey: message.invocationId)
        }

        if serverInvocationHandler != nil {
            Util.dispatchToMainThread {
                serverInvocationHandler!.processCompletion(completionMessage: message)
            }
        } else {
            logger.log(logLevel: .error, message: "Could not find callback with id \(message.invocationId)")
        }
    }

    private func handleStreamItem(message: StreamItemMessage) throws {
        var serverInvocationHandler: ServerInvocationHandler?
        self.hubConnectionQueue.sync {
            serverInvocationHandler = self.pendingCalls[message.invocationId]
        }

        if serverInvocationHandler != nil {
            Util.dispatchToMainThread {
                if let error = serverInvocationHandler!.processStreamItem(streamItemMessage: message) {
                    self.logger.log(logLevel: .error, message: "Processing stream item failed: \(error)")
                    self.failInvocationWithError(invocationHandler: serverInvocationHandler!, invocationId: message.invocationId, error: error)
                }
            }
        } else {
            logger.log(logLevel: .error, message: "Could not find callback with id \(message.invocationId)")
        }
    }

    private func handleInvocation(message: ClientInvocationMessage) {
        var callback: ((ArgumentExtractor) throws -> Void)?

        self.hubConnectionQueue.sync {
            callback = self.callbacks[message.target]
        }

        if callback != nil {
            Util.dispatchToMainThread {
                do {
                    try callback!(ArgumentExtractor(clientInvocationMessage: message))
                } catch {
                    self.logger.log(logLevel: .error, message: "Invoking client hub method \(message.target) failed due to: \(error)")
                }
            }
        } else {
            logger.log(logLevel: .error, message: "No handler registered for method \'\(message.target)\'")
        }
    }

    private func hubConnectionDidClose(error: Error?) {
        logger.log(logLevel: .info, message: "HubConnection closing with error: \(String(describing: error))")

        var invocationHandlers: [ServerInvocationHandler] = []
        hubConnectionQueue.sync {
            invocationHandlers = [ServerInvocationHandler](pendingCalls.values)
            pendingCalls.removeAll()
        }

        logger.log(logLevel: .info, message: "Terminating \(invocationHandlers.count) pending hub methods")
        let invocationError = error ?? SignalRError.hubInvocationCancelled
        for serverInvocationHandler in invocationHandlers {
            Util.dispatchToMainThread {
                serverInvocationHandler.raiseError(error: invocationError)
            }
        }

        delegate?.connectionDidClose(error: error)
    }

    public func connectionDidOpen(connection: Connection!) {
        connectionStarted()
    }

    public func connectionDidFailToOpen(error: Error) {
        delegate?.connectionDidFailToOpen(error: error)
    }

    public func connectionDidReceiveData(connection: Connection!, data: Data) {
        hubConnectionDidReceiveData(data: data)
    }

    public func connectionDidClose(error: Error?) {
        hubConnectionDidClose(error: error)
    }
}

public class ArgumentExtractor {
    let clientInvocationMessage: ClientInvocationMessage

    init(clientInvocationMessage: ClientInvocationMessage) {
        self.clientInvocationMessage = clientInvocationMessage
    }

    public func getArgument<T: Decodable>(type: T.Type) throws -> T {
        return try clientInvocationMessage.getArgument(type: type)
    }

    public func hasMoreArgs() -> Bool {
        return clientInvocationMessage.hasMoreArgs
    }
}

public extension HubConnection {
    func on(method: String, callback: @escaping () -> Void) {
        let cb: (ArgumentExtractor) throws -> Void = { argumentExtractor in
            callback()
        }

        self.on(method: method, callback: cb)
    }

    func on<T1: Decodable>(method: String, callback: @escaping (_ arg1: T1) -> Void) {
        let cb: (ArgumentExtractor) throws -> Void = { argumentExtractor in
            let arg1 = try argumentExtractor.getArgument(type: T1.self)
            callback(arg1)
        }

        self.on(method: method, callback: cb)
    }

    func on<T1: Decodable, T2: Decodable>(method: String, callback: @escaping (_ arg1: T1, _ arg2: T2) -> Void) {
        let cb: (ArgumentExtractor) throws -> Void = { argumentExtractor in
            let arg1 = try argumentExtractor.getArgument(type: T1.self)
            let arg2 = try argumentExtractor.getArgument(type: T2.self)
            callback(arg1, arg2)
        }

        self.on(method: method, callback: cb)
    }

    func on<T1: Decodable, T2: Decodable, T3: Decodable>(method: String, callback: @escaping (_ arg1: T1, _ arg2: T2, _ arg3: T3) -> Void) {
        let cb: (ArgumentExtractor) throws -> Void = { argumentExtractor in
            let arg1 = try argumentExtractor.getArgument(type: T1.self)
            let arg2 = try argumentExtractor.getArgument(type: T2.self)
            let arg3 = try argumentExtractor.getArgument(type: T3.self)
            callback(arg1, arg2, arg3)
        }

        self.on(method: method, callback: cb)
    }

    func on<T1: Decodable, T2: Decodable, T3: Decodable, T4: Decodable>(method: String, callback: @escaping (_ arg1: T1, _ arg2: T2, _ arg3: T3, _ arg4: T4) -> Void) {
        let cb: (ArgumentExtractor) throws -> Void = { argumentExtractor in
            let arg1 = try argumentExtractor.getArgument(type: T1.self)
            let arg2 = try argumentExtractor.getArgument(type: T2.self)
            let arg3 = try argumentExtractor.getArgument(type: T3.self)
            let arg4 = try argumentExtractor.getArgument(type: T4.self)
            callback(arg1, arg2, arg3, arg4)
        }

        self.on(method: method, callback: cb)
    }

    func on<T1: Decodable, T2: Decodable, T3: Decodable, T4: Decodable, T5: Decodable>(method: String, callback: @escaping (_ arg1: T1, _ arg2: T2, _ arg3: T3, _ arg4: T4, _ arg5: T5) -> Void) {
        let cb: (ArgumentExtractor) throws -> Void = { argumentExtractor in
            let arg1 = try argumentExtractor.getArgument(type: T1.self)
            let arg2 = try argumentExtractor.getArgument(type: T2.self)
            let arg3 = try argumentExtractor.getArgument(type: T3.self)
            let arg4 = try argumentExtractor.getArgument(type: T4.self)
            let arg5 = try argumentExtractor.getArgument(type: T5.self)

            callback(arg1, arg2, arg3, arg4, arg5)
        }

        self.on(method: method, callback: cb)
    }

    func on<T1: Decodable, T2: Decodable, T3: Decodable, T4: Decodable, T5: Decodable, T6: Decodable>(method: String, callback: @escaping (_ arg1: T1, _ arg2: T2, _ arg3: T3, _ arg4: T4, _ arg5: T5, _ arg6: T6) -> Void) {
        let cb: (ArgumentExtractor) throws -> Void = { argumentExtractor in
            let arg1 = try argumentExtractor.getArgument(type: T1.self)
            let arg2 = try argumentExtractor.getArgument(type: T2.self)
            let arg3 = try argumentExtractor.getArgument(type: T3.self)
            let arg4 = try argumentExtractor.getArgument(type: T4.self)
            let arg5 = try argumentExtractor.getArgument(type: T5.self)
            let arg6 = try argumentExtractor.getArgument(type: T6.self)

            callback(arg1, arg2, arg3, arg4, arg5, arg6)
        }

        self.on(method: method, callback: cb)
    }

    func on<T1: Decodable, T2: Decodable, T3: Decodable, T4: Decodable, T5: Decodable, T6: Decodable, T7: Decodable>(method: String, callback: @escaping (_ arg1: T1, _ arg2: T2, _ arg3: T3, _ arg4: T4, _ arg5: T5, _ arg6: T6, _ arg7: T7) -> Void) {
        let cb: (ArgumentExtractor) throws -> Void = { argumentExtractor in
            let arg1 = try argumentExtractor.getArgument(type: T1.self)
            let arg2 = try argumentExtractor.getArgument(type: T2.self)
            let arg3 = try argumentExtractor.getArgument(type: T3.self)
            let arg4 = try argumentExtractor.getArgument(type: T4.self)
            let arg5 = try argumentExtractor.getArgument(type: T5.self)
            let arg6 = try argumentExtractor.getArgument(type: T6.self)
            let arg7 = try argumentExtractor.getArgument(type: T7.self)

            callback(arg1, arg2, arg3, arg4, arg5, arg6, arg7)
        }

        self.on(method: method, callback: cb)
    }

    func on<T1: Decodable, T2: Decodable, T3: Decodable, T4: Decodable, T5: Decodable, T6: Decodable, T7: Decodable, T8: Decodable>(method: String, callback: @escaping (_ arg1: T1, _ arg2: T2, _ arg3: T3, _ arg4: T4, _ arg5: T5, _ arg6: T6, _ arg7: T7, _ arg8: T8) -> Void) {
        let cb: (ArgumentExtractor) throws -> Void = { argumentExtractor in
            let arg1 = try argumentExtractor.getArgument(type: T1.self)
            let arg2 = try argumentExtractor.getArgument(type: T2.self)
            let arg3 = try argumentExtractor.getArgument(type: T3.self)
            let arg4 = try argumentExtractor.getArgument(type: T4.self)
            let arg5 = try argumentExtractor.getArgument(type: T5.self)
            let arg6 = try argumentExtractor.getArgument(type: T6.self)
            let arg7 = try argumentExtractor.getArgument(type: T7.self)
            let arg8 = try argumentExtractor.getArgument(type: T8.self)
            callback(arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8)
        }

        self.on(method: method, callback: cb)
    }
}

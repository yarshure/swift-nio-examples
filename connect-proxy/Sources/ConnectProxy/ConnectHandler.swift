//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOHTTP1
import Logging


final class ConnectHandler {
    private var upgradeState: State
    private var connectType:ConnectType = .http
    private var logger: Logger
    private var reqHeader:HTTPRequestHead?
    init(logger: Logger) {
        self.upgradeState = .idle
        self.logger = logger
        
    }
}


extension ConnectHandler {
    fileprivate enum State {
        case idle
        case beganConnecting
        case awaitingEnd(connectResult: Channel)
        case awaitingConnection(pendingBytes: [NIOAny])
        case upgradeComplete(pendingBytes: [NIOAny])
        case upgradeFailed
    }
    fileprivate enum ConnectType {
        case http   //normal GET/POST
        case https //CONNECT
    }
}


extension ConnectHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        print(data)
        switch self.upgradeState {
        case .idle:
            self.handleInitialMessage(context: context, data: self.unwrapInboundIn(data))

        case .beganConnecting:
            // We got .end, we're still waiting on the connection
            if case .end = self.unwrapInboundIn(data) {
                self.upgradeState = .awaitingConnection(pendingBytes: [])
                self.removeDecoder(context: context)
            }

        case .awaitingEnd(let peerChannel):
            if case .end = self.unwrapInboundIn(data) {
                // Upgrade has completed!
                self.upgradeState = .upgradeComplete(pendingBytes: [])
                self.removeDecoder(context: context)
                self.glue(peerChannel, context: context)
            }

        case .awaitingConnection(var pendingBytes):
            // We've seen end, this must not be HTTP anymore. Danger, Will Robinson! Do not unwrap.
            self.upgradeState = .awaitingConnection(pendingBytes: [])
            pendingBytes.append(data)
            self.upgradeState = .awaitingConnection(pendingBytes: pendingBytes)

        case .upgradeComplete(pendingBytes: var pendingBytes):
            // We're currently delivering data, keep doing so.
            self.upgradeState = .upgradeComplete(pendingBytes: [])
            pendingBytes.append(data)
            self.upgradeState = .upgradeComplete(pendingBytes: pendingBytes)

        case .upgradeFailed:
            break
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Add logger metadata.
        self.logger[metadataKey: "localAddress"] = "\(String(describing: context.channel.localAddress))"
        self.logger[metadataKey: "remoteAddress"] = "\(String(describing: context.channel.remoteAddress))"
        self.logger[metadataKey: "channel"] = "\(ObjectIdentifier(context.channel))"
    }
}


extension ConnectHandler: RemovableChannelHandler {
    func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
        var didRead = false

        // We are being removed, and need to deliver any pending bytes we may have if we're upgrading.
        while case .upgradeComplete(var pendingBytes) = self.upgradeState, pendingBytes.count > 0 {
            // Avoid a CoW while we pull some data out.
            self.upgradeState = .upgradeComplete(pendingBytes: [])
            let nextRead = pendingBytes.removeFirst()
            self.upgradeState = .upgradeComplete(pendingBytes: pendingBytes)

            context.fireChannelRead(nextRead)
            didRead = true
        }

        if didRead {
            context.fireChannelReadComplete()
        }

        self.logger.debug("Removing \(self) from pipeline")
        context.leavePipeline(removalToken: removalToken)
    }
}

extension ConnectHandler {
    private func handleInitialMessage(context: ChannelHandlerContext, data: InboundIn) {
        guard case .head(var head) = data else {
            self.logger.error("Invalid HTTP message type \(data)")
            self.httpErrorAndClose(context: context)
            return
        }

        self.logger.info("\(head.method) \(head.uri) \(head.version)")

     

       

        //stand http proxy
        //Invalid HTTP method Invalid HTTP method: GET
        if head.method == .CONNECT {
              // Port 80 if not specified
            guard let connectInfo = head.hostPort(connect: true) else {
                //when fail,need close channel
                     self.logger.error("Invalid HTTP  \(head.uri)")
                     self.httpErrorAndClose(context: context)
                return
            }
            self.connectType = .https
            self.upgradeState = .beganConnecting
            self.connectTo(host: connectInfo.0, port: connectInfo.1, context: context)
        }else {
            //need updat uri?
            guard let connectInfo = head.hostPort(connect: false) else {
                self.logger.error("Invalid HTTP  \(head.headers)")
                self.httpErrorAndClose(context: context)
                return
            }
            self.upgradeState = .beganConnecting
            self.connectTo(host: connectInfo.0, port: connectInfo.1, context: context)
            //update uri
            head.uri = head.shortUri
            self.reqHeader = head
            
        }
     

    }

    private func connectTo(host: String, port: Int, context: ChannelHandlerContext) {
        self.logger.info("Connecting to \(host):\(port)")

        let channelFuture = ClientBootstrap(group: context.eventLoop)
            .connect(host: String(host), port: port)

        channelFuture.whenSuccess { channel in
            self.connectSucceeded(channel: channel, context: context)
        }
        channelFuture.whenFailure { error in
            self.connectFailed(error: error, context: context)
        }
    }

    private func connectSucceeded(channel: Channel, context: ChannelHandlerContext) {
        self.logger.info("Connected to \(String(describing: channel.remoteAddress))")


        switch self.upgradeState {
        case .beganConnecting:
            // Ok, we have a channel, let's wait for end.
            self.upgradeState = .awaitingEnd(connectResult: channel)

        case .awaitingConnection(pendingBytes: let pendingBytes):
            // Upgrade complete! Begin gluing the connection together.
            self.upgradeState = .upgradeComplete(pendingBytes: pendingBytes)
            self.glue(channel, context: context)

        case .idle, .awaitingEnd, .upgradeFailed, .upgradeComplete:
            // These cases are logic errors, but let's be careful and just shut the connection.
            context.close(promise: nil)
        }
    }

    private func connectFailed(error: Error, context: ChannelHandlerContext) {
        self.logger.error("Connect failed: \(error)")

        switch self.upgradeState {
        case .beganConnecting, .awaitingConnection:
            // We still have a somewhat active connection here in HTTP mode, and can report failure.
            self.httpErrorAndClose(context: context)

        case .idle, .awaitingEnd, .upgradeFailed, .upgradeComplete:
            // Most of these cases are logic errors, but let's be careful and just shut the connection.
            context.close(promise: nil)
        }

        context.fireErrorCaught(error)
    }

    private func glue(_ peerChannel: Channel, context: ChannelHandlerContext) {
        self.logger.debug("Gluing together \(ObjectIdentifier(context.channel)) and \(ObjectIdentifier(peerChannel))")

        // Ok, upgrade has completed! We now need to begin the upgrade process.
        // First, send the 200 message.
        // This content-length header is MUST NOT, but we need to workaround NIO's insistence that we set one.
        

        if connectType == .https {
            let headers = HTTPHeaders([("Content-Length", "0")])
            let head = HTTPResponseHead(version: .init(major: 1, minor: 1), status: .ok, headers: headers)
            context.write(self.wrapOutboundOut(.head(head)), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }else {
           // send http header to real server
            if let head = reqHeader   {
                                //let part = HTTPPart
                    var buf = ByteBufferAllocator().buffer(capacity: 1024)
                   
                    buf.writeString(head.genData())
                    for header in head.headers {
                        if header.0 !=  "Proxy-Connection" {
                            buf.writeString(header.0)
                            buf.writeStaticString(": ")
                            buf.writeString(header.1)
                            buf.writeStaticString("\r\n")
                        }
                            
                    }
                    buf.writeStaticString("\r\n")
                    let data = NIOAny.init( buf)
                    self.upgradeState = .upgradeComplete(pendingBytes: [data])
                self.reqHeader = nil
            }
                
           
        }
        // Now remove the HTTP encoder.
        self.removeEncoder(context: context)

        // Now we need to glue our channel and the peer channel together.
        let (localGlue, peerGlue) = GlueHandler.matchedPair()
        context.channel.pipeline.addHandler(localGlue).and(peerChannel.pipeline.addHandler(peerGlue)).whenComplete { result in
            context.pipeline.removeHandler(self, promise: nil)
        }
    }

    private func httpErrorAndClose(context: ChannelHandlerContext) {
        self.upgradeState = .upgradeFailed

        let headers = HTTPHeaders([("Content-Length", "0"), ("Connection", "close")])
        let head = HTTPResponseHead(version: .init(major: 1, minor: 1), status: .badRequest, headers: headers)
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        context.write(self.wrapOutboundOut(.end(nil))).whenComplete { (_: Result<Void, Error>) in
            context.close(mode: .output, promise: nil)
        }
    }

    private func removeDecoder(context: ChannelHandlerContext) {
        // We drop the future on the floor here as these handlers must all be in our own pipeline, and this should
        // therefore succeed fast.
        context.pipeline.context(handlerType: ByteToMessageHandler<HTTPRequestDecoder>.self).whenSuccess {
            context.pipeline.removeHandler(context: $0, promise: nil)
        }
    }

    private func removeEncoder(context: ChannelHandlerContext) {
        context.pipeline.context(handlerType: HTTPResponseEncoder.self).whenSuccess {
            context.pipeline.removeHandler(context: $0, promise: nil)
        }
    }
}

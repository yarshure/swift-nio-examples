//
//  HTTPExtension.swift
//  httpproxyserver
//
//  Created by yarshure on 2/28/20.
//

import Foundation
import NIO

import NIOHTTP1

extension HTTPRequestHead{
    var shortUri:String {
        let componts = uri.split(separator: "/",maxSplits: 2)
        if componts.count == 2 {
            return "/"
        }else {
            return "/" + componts[2]
        }
        
    }
    func hostPort(connect:Bool) ->(String,Int)? {
        if connect {
            let components = self.uri.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let host = String(components.first!)  // There will always be a first.
            let port = components.last.flatMap { Int($0, radix: 10) } ?? 80
            return (host,port)
        }else {
            for item in self.headers {
                if  item.name ==  "Host" {
                    //let idxs = item.value.split(separator: ":")
                    let components = item.value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                     let host = String(components.first!)
                    //let port = Int(String(idxs[1]))!
                     let port = components.last.flatMap { Int($0, radix: 10) } ?? 80
                    return (host,port)
                }
            }
        }
        return nil
    }
    func genData() ->String{
      
        let  result:String = "\(method.rawValue) \(uri) HTTP/\(version.major).\(version.minor)\r\n"
       return result
    }
}

//
//  BluFiManager.swift
//  BluFiExample
//
//  Created by Tuan PM on 9/10/18.
//  Copyright © 2018 Tuan PM. All rights reserved.
//


import Foundation
import CryptoSwift
import PromiseKit
import AwaitKit

extension Data {
    struct HexEncodingOptions: OptionSet {
        let rawValue: Int
        static let upperCase = HexEncodingOptions(rawValue: 1 << 0)
    }
    
    func toHexString(options: HexEncodingOptions = []) -> String {
        return map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    
}

struct BluFiError: Error {
    var code = 0
    var msg = ""
    public init(_ msg: String) {
        self.msg = msg
    }
    public init(_ code: Int) {
        self.code = code
    }
}

public final class BluFiMangager: NSObject {
    
   
    private let DH_P = "cf5cf5c38419a724957ff5dd323b9c45c3cdd261eb740f69aa94b8bb1a5c9640" +
        "9153bd76b24222d03274e4725a5406092e9e82e9135c643cae98132b0d95f7d6" +
        "5347c68afc1e677da90e51bbab5f5cf429c291b4ba39c6b2dc5e8c7231e46aa7" +
    "728e87664532cdf547be20c9a3fa8342be6e34371a27c06f7dc0edddd2f86373"
    private let DH_G = "2"
    
    private let DIRECTION_INPUT = 1
    private let DIRECTION_OUTPUT = 0
    private let WRITE_TIMEOUT_SECOND = 10
    private let DEFAULT_PACKAGE_LENGTH = 80
    private let PACKAGE_HEADER_LENGTH = 4
    
    private var writeToBluetooth: ((Data) -> Void)?
    private let ackSem = DispatchSemaphore(value: 0)
    private let readSem = DispatchSemaphore(value: 0)
    private let bleStateSem = DispatchSemaphore(value: 0)
    private let writeLock = DispatchSemaphore(value: 1)
    private var dataRead: [UInt8] = []
    //    private let dispatchGroup = DispatchGroup()
    private var sendSequence: Int = 0
    private var recvSequence: Int = 0
    private var ackSequence: Int = -1
    private var mPackageLengthLimit: Int
    private var requireAck: Bool = false
    private var mNotiData: BlufiNotiData? = nil
    private var secDHKeys: DHKey? = nil
    private var md5SecKey: [UInt8] = []
    private var mEncrypted = false
    private var mChecksum = true
    
    private func generateSeq() -> Int {
        let seq = sendSequence
        sendSequence += 1
        return seq
    }
    private func getSeq() -> Int {
        let saveSeq = recvSequence
        recvSequence += 1
        return saveSeq
    }
    
    private func generateAESIV(_ sequence: Int) -> [UInt8] {
        var result: [UInt8] = Array(repeating: 0, count: 16)
        result[0] = UInt8(sequence)
        return result;
    }
    
    private func getTypeValue(type: Int, subtype: Int) -> Int {
        return (subtype << 2) | type
    }
    
    private func getPackageType(typeValue: Int) -> Int {
        return typeValue & 0x3
    }
    
    private func getSubType(typeValue: Int) -> Int {
        return ((typeValue & 0xfc) >> 2)
    }
    
    private func getFrameCtrlValue(encrypt: Bool, checksum: Bool, direction: Int, requireAck: Bool, frag: Bool) -> Int {
        var frame: Int = 0;
        if encrypt {
            frame = frame | (1 << FRAME_CTRL.POSITION_ENCRYPTED);
        }
        if checksum {
            frame = frame | (1 << FRAME_CTRL.POSITION_CHECKSUM);
        }
        if direction == DIRECTION_INPUT {
            frame = frame | (1 << FRAME_CTRL.POSITION_DATA_DIRECTION);
        }
        if requireAck {
            frame = frame | (1 << FRAME_CTRL.POSITION_REQUIRE_ACK);
        }
        if frag {
            frame = frame | (1 << FRAME_CTRL.POSITION_FRAG);
        }
        
        return frame;
    }
    
    private func getPostBytes(type: Int, frameCtrl: Int, sequence: Int, dataLength: Int, data: [UInt8]) -> [UInt8] {
        var byteList = [UInt8]()
        byteList.append(UInt8(type))
        byteList.append(UInt8(frameCtrl))
        byteList.append(UInt8(sequence))
        
        let frameCtrlData = FrameCtrlData(frameCtrlValue: frameCtrl)
        var checksumBytes: [UInt8] = []
        var resultData = data;
        var pkgLen = dataLength
        if frameCtrlData.hasFrag() {
            pkgLen += 2
        }
        byteList.append(UInt8(pkgLen))
        
        if frameCtrlData.isChecksum() {
            
            var checkByteList: [UInt8] = []
            checkByteList.append(UInt8(sequence));
            checkByteList.append(UInt8(pkgLen));
            checkByteList.append(contentsOf: data)
            checksumBytes = CRC.getCRC16(data_p: checkByteList)
        }
        
        if frameCtrlData.isEncrypted() && data.count > 0 {
            do {
                let iv = generateAESIV(sequence)
                let aes = try AES(key: md5SecKey, blockMode: CFB(iv: iv), padding: .noPadding)
                resultData = try aes.encrypt(data)
            } catch {
                resultData = data
            }
            
        }
        byteList.append(contentsOf: resultData)
        if frameCtrlData.isChecksum() {
            byteList.append(contentsOf: checksumBytes)
        }
        return byteList
    }
    
    
    private func resetSeq() {
        sendSequence = 0
        recvSequence = 0
    }
    
    private func read(_ timeout_sec: Int) -> Promise<BlufiNotiData> {
        return Promise {
            let blufiData: BlufiNotiData = BlufiNotiData()
            while true {
                let timeout = DispatchTime.now() + .seconds(timeout_sec)
                if readSem.wait(timeout: timeout) != .success {
                    print("read timeout")
                    return $0.reject(BluFiError("Timeout"))
                }
                if dataRead.count < 4 {
                    return $0.reject(BluFiError("Invalid response data"))
                }
                let parse = parseNotification(data: dataRead, notification: blufiData)
                
                if parse < 0 {
                    return $0.reject(BluFiError("Error parse data"))
                } else if parse == 0 {
                    return $0.resolve(blufiData, nil)
                }
            }
        }
    }
    
    // Write raw data without response
    private func writeRaw(_ data: [UInt8]) -> Promise<Bool> {
        return Promise {
            if data.count ==  0 {
                return $0.reject(BluFiError("Invalid write data"))
            }
            let needWrite = Data.init(bytes: UnsafePointer<UInt8>(data), count: data.count)
            writeLock.wait()
            writeToBluetooth?(needWrite)
//            activePeripheral?.writeValue(needWrite, for: dataOutCharacteristics!, type: .withResponse)
            writeLock.signal()
            return $0.resolve(true, nil)
        }
    }
    
    // Write raw data and wait for response
    private func write(_ data: [UInt8], _ timeoutSec: Int, _ needResponse: Bool) -> Promise<BlufiNotiData> {
        return async {
            try await(self.writeRaw(data))
            if self.requireAck {
                let bluFiData = try await(self.read(timeoutSec))
                let ackSeq = self.getAckSeq(bluFiData)
                if ackSeq != self.sendSequence - 1 {
                    throw BluFiError("Invalid ACK Seq, send seq = \(self.sendSequence), ack Seq = \(ackSeq)")
                }
            }
            if !needResponse {
                return BlufiNotiData()
            }
            return try await(self.read(timeoutSec))
        }
    }
    
    // Write data frame and wait for response
    private func writeFrame(_ type: Int, _ data: [UInt8], _ timeoutSec: Int,  _ needResponse: Bool) -> Promise<BlufiNotiData> {
        return async {
            var dataRemain = data
            repeat {
                
                var postDataLengthLimit = self.mPackageLengthLimit - self.PACKAGE_HEADER_LENGTH;
                if self.mChecksum {
                    postDataLengthLimit -= 2
                }
                let sequence = self.generateSeq()
                if dataRemain.count > postDataLengthLimit {
                    let frameCtrl = self.getFrameCtrlValue(encrypt: self.mEncrypted,
                                                           checksum: self.mChecksum,
                                                           direction: self.DIRECTION_OUTPUT,
                                                           requireAck: self.requireAck,
                                                           frag: true)
                    
                    let totleLen = dataRemain.count
                    let totleLen1 = totleLen & 0xff
                    let totleLen2 = (totleLen >> 8) & 0xff
                    var partToWrite = dataRemain[0..<postDataLengthLimit]
                    let partRemain = dataRemain[postDataLengthLimit...]
                    
                    partToWrite.insert(UInt8(totleLen2), at: 0)
                    partToWrite.insert(UInt8(totleLen1), at: 0)
                    
                    
                    let postBytes = self.getPostBytes(type: type,
                                                      frameCtrl: frameCtrl,
                                                      sequence: sequence,
                                                      dataLength: postDataLengthLimit,
                                                      data: Array(partToWrite))
                    _ = try await(self.write(postBytes, timeoutSec, false))
                    dataRemain = Array(partRemain)
                } else {
                    let frameCtrl = self.getFrameCtrlValue(encrypt: self.mEncrypted,
                                                           checksum: self.mChecksum,
                                                           direction: self.DIRECTION_OUTPUT,
                                                           requireAck: self.requireAck,
                                                           frag: false)
                    
                    let postBytes = self.getPostBytes(type: type,
                                                      frameCtrl: frameCtrl,
                                                      sequence: sequence,
                                                      dataLength: dataRemain.count,
                                                      data: dataRemain)
                    return try await(self.write(postBytes, timeoutSec, needResponse))
                }
            } while true
        }
        
    }
    
    private func getAckSeq(_ bluFiData: BlufiNotiData) -> Int {
        let pkgType = bluFiData.getPkgType()
        let subType = bluFiData.getSubType()
        let data = bluFiData.getDataArray()
        if (data.count < 1) {
            return -1
        }
        if pkgType == Type.Ctrl.PACKAGE_VALUE &&
            subType == Type.Ctrl.SUBTYPE_ACK {
            return Int(data[0] & 0xff)
        }
        return -1
    }
    
    private func validPackage(_ blufiData: BlufiNotiData, _ type: Int, _ subType: Int) -> Bool {
        let pkgType = blufiData.getPkgType()
        let sType = blufiData.getSubType()
        if pkgType != type || subType != sType {
            return false
        }
        return true
    }
    
    public func negotiate() -> Promise<Bool> {
        return async {
            self.resetSeq()
            /* 1. Write package length */
            let type = self.getTypeValue(type: Type.Data.PACKAGE_VALUE, subtype: Type.Data.SUBTYPE_NEG)
            self.secDHKeys = DHKeyExchange.genDHExchangeKeys(generator: self.DH_G, primeNumber: self.DH_P)
            let pKey = DHKey.hexStringToBytes(self.DH_P)
            let gKey = DHKey.hexStringToBytes(self.DH_G)
            let kKey = self.secDHKeys!.publicKeyAsArray()
            let pgkLength = pKey.count + gKey.count + kKey.count + 6
            let pgkLen1 = UInt8((pgkLength >> 8) & 0xff)
            let pgkLen2 = UInt8(pgkLength & 0xff)
            
            var dataList: [UInt8] = [UInt8(NEG_SET_SEC.TOTAL_LEN), pgkLen1, pgkLen2]
            _ = try await(self.writeFrame(type, dataList, self.WRITE_TIMEOUT_SECOND, false))
            
            /* Write package data */
            dataList = [UInt8(NEG_SET_SEC.ALL_DATA)]
            dataList.append(UInt8((pKey.count >> 8) & 0xff))
            dataList.append(UInt8(pKey.count & 0xff))
            dataList.append(contentsOf: pKey)
            
            dataList.append(UInt8((gKey.count >> 8) & 0xff))
            dataList.append(UInt8(gKey.count & 0xff))
            dataList.append(contentsOf: gKey)
            
            dataList.append(UInt8((kKey.count >> 8) & 0xff))
            dataList.append(UInt8(kKey.count & 0xff))
            dataList.append(contentsOf: kKey)
            let respData = try await(self.writeFrame(type, dataList, self.WRITE_TIMEOUT_SECOND, true))
            
            /* Read and parse response, process security data */
            if !self.validPackage(respData, Type.Data.PACKAGE_VALUE, Type.Data.SUBTYPE_NEG) {
                self.resetSeq()
                throw BluFiError("Invalid response")
            }
            
            let data = respData.getDataArray()
            let keyStr = data.map{String(format: "%02X", $0)}.joined(separator: "")
            let privatedDHKey = (self.secDHKeys?.privateKey)!
            
            let cryptoDHKey = DHKeyExchange.genDHCryptoKey(
                privateDHKey: privatedDHKey,
                serverPublicDHKey: keyStr,
                primeNumber: self.DH_P)
            let md5 = MD5()
            self.md5SecKey = md5.calculate(for: DHKey.hexStringToBytes(cryptoDHKey))
            self.mEncrypted = true
            self.mChecksum = true
            
            /* Set security */
            let secType = self.getTypeValue(type: Type.Ctrl.PACKAGE_VALUE, subtype: Type.Ctrl.SUBTYPE_SET_SEC_MODE)
            var secData = 0
            // data checksum
            secData = secData | 1
            
            // data Encrypt
            secData = secData | (1 << 1)
            
            let postData: [UInt8] = [UInt8(secData)]
            _ = try await(self.writeFrame(secType, postData, self.WRITE_TIMEOUT_SECOND, false))
            return true
        }
    }

    
    writeCustomData(_ data: [UInt8], _ needResponse: Bool) -> Promise<[UInt8]> {
        return writeCustomData(data, needResponse ? self.WRITE_TIMEOUT_SECOND : 0)
    }
    
    
    public func writeCustomData(_ data: [UInt8], _ timeout_sec: Int = 0) -> Promise<[UInt8]> {
        return async {

            // 데이터 유형 및 하위 유형에 대한 값 설정
            let type = self.getTypeValue(type: Type.Data.PACKAGE_VALUE, subtype: Type.Data.SUBTYPE_CUSTOM_DATA)
            
            // 응답이 필요하지 여부 확인 
            let needResponse = timeout_sec > 0
            // 프레임 쓰기 및 응답 대기
            let respData = try await(self.writeFrame(type, data, timeout_sec, needResponse))
            
            // 응답이 필요하지 않은 경우 빈 배열 반환
            if !needResponse {
                return []
            }
            // 수신한 응답 패키지의 유효성 확인
            if !self.validPackage(respData, Type.Data.PACKAGE_VALUE, Type.Data.SUBTYPE_CUSTOM_DATA) {
                // 시퀀스 재설정 및 잘못된 응답으로 예외 throw
                self.resetSeq()
                throw BluFiError("Invalid response for custom data")
            }
            // 응답 데이터 배열 반환
            return respData.getDataArray()
        }
    }
    
    public func getWiFiScanList() -> Promise<[WiFiEntry]> {
        return async {
            let type = self.getTypeValue(type: Type.Ctrl.PACKAGE_VALUE, subtype: Type.Ctrl.SUBTYPE_GET_WIFI_LIST)
            let respData = try await(self.writeFrame(type, [], self.WRITE_TIMEOUT_SECOND, true))
    
            if !self.validPackage(respData, Type.Data.PACKAGE_VALUE, Type.Data.SUBTYPE_WIFI_LIST) {
                self.resetSeq()
                throw BluFiError("Invalid response for getWiFiScanList")
            }
            let arrList = respData.getDataArray()
            var strList = [WiFiEntry]()
            var idx = 0
            while idx <  arrList.count {
                // SSID 길이 및 RSSI 정보 추출
                let len = Int(arrList[idx+0])
                let rssi = Int8(bitPattern: arrList[idx+1])
                let offsetBegin = idx + 2
                let offsetEnd = idx + len + 1
                
                // Wi-Fi 목록 배열 길이 확인
                if offsetEnd > arrList.count {
                    throw BluFiError("Invalid wifi list array len")
                }

                // SSID 정보 추출 및 Wi-FiEntry 객체 생성 
                let nameArr = Array(arrList[offsetBegin..<offsetEnd])
                let name = String(bytes: nameArr, encoding: .utf8)
                strList.append(WiFiEntry(name!, rssi))
                idx = offsetEnd
            }
            return strList
        }
    }
    
    public func getDeviceVersion() -> Promise<[UInt8]> {
        return async {
            let type = self.getTypeValue(type: Type.Ctrl.PACKAGE_VALUE, subtype: Type.Ctrl.SUBTYPE_GET_VERSION)
            let respData = try await(self.writeFrame(type, [], self.WRITE_TIMEOUT_SECOND, true))
            if !self.validPackage(respData, Type.Data.PACKAGE_VALUE, Type.Data.SUBTYPE_VERSION) {
                self.resetSeq()
                throw BluFiError("Invalid response for getDeviceVersion")
            }
            let versionData = respData.getDataArray()
            if versionData.count != 2 {
                throw BluFiError("Invalid version format")
            }
            return versionData
        }
    }
    
    public func getDeviceStatus() -> Promise<[UInt8]> {
        return async {
            // Wi-Fi 상태 조회 명령의 타입 값 설정
            let type = self.getTypeValue(type: Type.Ctrl.PACKAGE_VALUE, subtype: Type.Ctrl.SUBTYPE_GET_WIFI_STATUS)
            
            // Wi-Fi 상태 조회 명령 전송 및 응답 수신
            let respData = try await(self.writeFrame(type, [], self.WRITE_TIMEOUT_SECOND, true))
            
            // 응답 패키지 유효성 검사
            if !self.validPackage(respData, Type.Data.PACKAGE_VALUE, Type.Data.SUBTYPE_WIFI_CONNECTION_STATE) {
                self.resetSeq()
                throw BluFiError("Invalid response for getDeviceStatus")
            }
            // 응답 데이터 반환 
            return respData.getDataArray()
        }
    }
    
    // 와이파이 연결 설정
    public func setWiFiSta(_ ssid: String, _ password: String) -> Promise<[UInt8]> {
        return async {
             // SSID 설정 명령 타입 설정
            var type = self.getTypeValue(type: Type.Data.PACKAGE_VALUE, subtype: Type.Data.SUBTYPE_STA_WIFI_SSID)
            // SSID 데이터 전송
            _ = try await(self.writeFrame(type, [UInt8](ssid.utf8), self.WRITE_TIMEOUT_SECOND, false))
            
            // 패스워드 설정 명령 타입 설정
            type = self.getTypeValue(type: Type.Data.PACKAGE_VALUE, subtype: Type.Data.SUBTYPE_STA_WIFI_PASSWORD)
            // 패스워드 설정 명령 타입 설정
            _ = try await(self.writeFrame(type, [UInt8](password.utf8), self.WRITE_TIMEOUT_SECOND, false))
            // Wi-Fi 연결 명령 타입 설정
            type = self.getTypeValue(type: Type.Ctrl.PACKAGE_VALUE, subtype: Type.Ctrl.SUBTYPE_CONNECT_WIFI)
            
            // Wi-Fi 연결 명령 전송 및 응답 수신
            let respData = try await(self.writeFrame(type, [UInt8](password.utf8), self.WRITE_TIMEOUT_SECOND, true))
            
            // 응답 패키지 유효성 검사
            if !self.validPackage(respData, Type.Data.PACKAGE_VALUE, Type.Data.SUBTYPE_WIFI_CONNECTION_STATE) {
                self.resetSeq()
                throw BluFiError("Invalid response for WiFi status")
            }
            // 응답 데이터 반환
            let dataArray = respData.getDataArray()
            if dataArray.count < 3 {
                throw BluFiError("Invalid data size")
            }
            return respData.getDataArray()
        }
    }
    
    public init(writeToBluetooth: @escaping (Data) -> Void) {
        self.writeToBluetooth = writeToBluetooth
        self.mPackageLengthLimit = DEFAULT_PACKAGE_LENGTH
        
        super.init()
    }
    
 
    public func readFromBluetooth(_ data: Data) -> Void {
        let resultBytes:[UInt8] = Array(UnsafeBufferPointer(start: (data as NSData).bytes.bindMemory(to: UInt8.self, capacity: data.count), count: data.count))
        dataRead = resultBytes
        readSem.signal()
    }
    
    public func read(_ data: [UInt8]) -> Void {
        dataRead = data
        readSem.signal()
    }
    
//    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
//        let data = characteristic.value
//        let resultBytes:[UInt8] = Array(UnsafeBufferPointer(start: (data! as NSData).bytes.bindMemory(to: UInt8.self, capacity: data!.count), count: data!.count))
//        dataRead = resultBytes
//        readSem.signal()
//    }
    
    private func parseNotification(data: [UInt8], notification: BlufiNotiData) -> Int {
        if data.count < 4 {
            print("parseNotification data length less than 4")
            return -2;
        }
        let sequence = Int(data[2])
        let recvSeq = getSeq()
        if sequence != recvSeq {
            print("wrong recvSEQ=\(sequence), appSEQ=\(recvSeq)")
            recvSequence = sequence - 1
            sendSequence = sequence
            //resetSeq()
            return -3
        }
        
        let type = Int(data[0])
        let pkgType = getPackageType(typeValue: type)
        let subType = getSubType(typeValue: type)
        
        notification.setType(typeValue: type)
        notification.setPkgType(pkgType: pkgType)
        notification.setSubType(subType: subType)
        
        let frameCtrl = Int(data[1])
        notification.setFrameCtrl(frameCtrl: frameCtrl)
        let frameCtrlData = FrameCtrlData(frameCtrlValue: frameCtrl)
        let dataLength = Int(data[3])
        var dataOffset = 4
        let cryptedDataBytes = Array(data[dataOffset..<dataOffset + dataLength])
        var dataBytes = cryptedDataBytes
        
        if frameCtrlData.isEncrypted() {
            do {
                let iv = generateAESIV(sequence)
                let aes = try AES(key: md5SecKey, blockMode: CFB(iv: iv), padding: .noPadding)
                dataBytes = try aes.decrypt(cryptedDataBytes)
            } catch {
                print("Error decrypt data")
            }
        }
        // var totleLen = 0
        if frameCtrlData.hasFrag() {
            // totleLen = Int(dataBytes[0] | (dataBytes[1] << 8))
            dataOffset = 2
        } else {
            dataOffset = 0
        }
        
        if frameCtrlData.isChecksum() {
            let respChecksum1 = data[data.count - 2]
            let respChecksum2 = data[data.count - 1]
            
            var checkByteList: [UInt8] = []
            checkByteList.append(UInt8(sequence));
            checkByteList.append(UInt8(dataLength));
            checkByteList.append(contentsOf: Array(dataBytes))
            let checksumBytes = CRC.getCRC16(data_p: checkByteList)
            if respChecksum1 != checksumBytes[0] || respChecksum2 != checksumBytes[1] {
                print("Invalid checksum, calc: \(checksumBytes.toHexString()) from data: \(String(format: "%02hhX", respChecksum1)) \(String(format: "%02hhX", respChecksum2))")
                return -1
            }
        }
        

        var notificationData = dataBytes
        if dataOffset > 0 {
            notificationData = Array(dataBytes[dataOffset...])
        }
        
        notification.addData(bytes: notificationData)
        return frameCtrlData.hasFrag() ? 1 : 0
    }
}




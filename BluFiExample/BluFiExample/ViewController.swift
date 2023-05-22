//
//  ViewController.swift
//  BluFiExample
//
//  Created by Tuan PM on 9/10/18.
//  Copyright © 2018 Tuan PM. All rights reserved.
//

import UIKit
import BluFi
import CoreBluetooth
import RxBluetoothKit
import RxSwift
import SystemConfiguration.CaptiveNetwork

class ViewController: UIViewController {
    
    var bluFi: BluFiMangager?
    let manager = CentralManager(queue: .main)
    private let bluFiServiceUUID = CBUUID(string: "0000ffff-0000-1000-8000-00805f9b34fb")
    private let bluFiDataOutCharsUUID = CBUUID(string: "0000ff01-0000-1000-8000-00805f9b34fb")
    private let bluFiDataInCharsUUID = CBUUID(string: "0000ff02-0000-1000-8000-00805f9b34fb")
    
    fileprivate      var activePeripheral: Peripheral!
    fileprivate      var activeService: Service!
    fileprivate      var dataOutCharacteristics: Characteristic?
    fileprivate      var dataInCharacteristics: Characteristic?
    var isBluFiFinish = false
    var blufi:Disposable? = nil
    
    @IBOutlet weak var setupWifi: UIButton!
    @IBOutlet weak var ssidTxt: UITextField!
    @IBOutlet weak var passTxt: UITextField!
    @IBOutlet weak var writeDataBtn: UIButton!
    @IBOutlet weak var lblIp: UILabel!
    @IBOutlet weak var lblModel: UILabel!
    @IBOutlet weak var lblHwID: UILabel!
    @IBOutlet weak var accessIdTxt: UITextField!
    @IBOutlet weak var accessKeyTxt: UITextField!
    @IBOutlet weak var writeNullBtn: UIButton!
    @IBOutlet weak var rebootButton: UIButton!
    @IBOutlet weak var exitCfgButton: UIButton!
    
    func scanAndConnect() {
        // 블루투스 상태 가져오기 
        let state: BluetoothState = manager.state

        // UI 요소 초기화 
        accessIdTxt.text = ""
        accessKeyTxt.text = ""
        lblHwID.text = ""
        lblModel.text = ""
        lblIp.text = ""
        
        // 버튼 비활성화 
        writeDataBtn.isEnabled = false
        writeNullBtn.isEnabled = false
        rebootButton.isEnabled = false
        exitCfgButton.isEnabled = false

        // 기존 blufi 객체 폐기
        if blufi != nil {
            blufi?.dispose()
        }

        // Bluetooth 상태 변경을 관찰
        blufi = manager.observeState()
            .startWith(state)
            .filter { $0 == .poweredOn }
            .flatMap { _ in self.manager.scanForPeripherals(withServices: [self.bluFiServiceUUID]) }
            .take(1)
            .flatMap { d in
                d.peripheral.establishConnection()
            }
            .flatMap { $0.discoverServices([self.bluFiServiceUUID]) }.asObservable()
            .flatMap { Observable.from($0) }
            .flatMap { $0.discoverCharacteristics([self.bluFiDataInCharsUUID, self.bluFiDataOutCharsUUID])}.asObservable()
            .flatMap { Observable.from($0) }
            .subscribe(onNext: { characteristic in

                // 블루투스 기기명 확인
                /* if let peripheralName = characteristic.service.peripheral.name {
                    print("블루투스 기기명: \(peripheralName)")
                } */
                
                // 데이터 입력 특성인 경우
                if characteristic.uuid == self.bluFiDataInCharsUUID {
                    self.dataInCharacteristics = characteristic

                    // 데이터 업데이트 및 알림 관찰
                    _ = characteristic
                        .observeValueUpdateAndSetNotification()
                        .subscribe(onNext: {
                            let data = $0.value
                            self.bluFi?.readFromBluetooth(data!)
                        })

                    // blufi 객체의 네고시에이션(negotiation) 수행 여부 확인
                    // 블루투스 연결이 완료된 후 'isBluFiFinish' 변수를 사용해 확인
                    self.isBluFiFinish = ((self.bluFi?.negotiate()) != nil)
                    
                    // 관련 버튼 활성화/비활성화
                    self.writeDataBtn.isEnabled = self.isBluFiFinish
                    self.writeNullBtn.isEnabled = self.isBluFiFinish
                    self.rebootButton.isEnabled = self.isBluFiFinish
                    self.exitCfgButton.isEnabled = self.isBluFiFinish
                }
                
                // 데이터 출력 특성인 경우
                if characteristic.uuid == self.bluFiDataOutCharsUUID {
                    self.dataOutCharacteristics = characteristic
                }
            })
        
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        bluFi = BluFiMangager(writeToBluetooth: { (data) in
            // 블루투스로 데이터를 쓰기 

            // 데이터를 블루투스로 작성하기 위해 dataOutCharacteristics 특성 사용
            _ = self.dataOutCharacteristics?
                .writeValue(data, type: .withResponse)
                .subscribe(onSuccess: { characteristic in
                    print("write done")
                }, onError: { error in
                    print("write error \(error)")
                })
        })
        
        
        scanAndConnect()
        ssidTxt.text = self.getWiFiSsid()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    

    func getWiFiSsid() -> String? {
        // wi-fi 인터페이스를 지원하는지 확인하고, 인터페이스 목록을 가져옵니다.
        guard let interfaces = CNCopySupportedInterfaces() as? [String] else { return nil }

        // wi-fi ssid를 가져오기 위한 키 값 설정
        let key = kCNNetworkInfoKeySSID as String

    // 인터페이스를 순회하며 Wi-Fi 네트워크 정보를 가져옵니다.
        for interface in interfaces {
            // 현재 인터페이스에 대한 네트워크 정보를 가져옵니다.
            guard let interfaceInfo = CNCopyCurrentNetworkInfo(interface as CFString) as NSDictionary? else { continue }

            // 네트워크 정보에서 SSID 값을 가져옵니다.
            return interfaceInfo[key] as? String
        }

        // SSID를 찾지 못한 경우 nil 반환
        return nil
    }
    
    func convertToDictionary(_ text: String) -> [String: Any]? {
        if let data = text.data(using: .utf8) {
            do {
                return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            } catch {
                print(error.localizedDescription)
            }
        }
        return nil
    }
    
    // 사용자가 입력한 데이터를 기반으로 블루투스 장치에 사용자 정의 데이터를 쓰는 작업을 수행한다.
    @IBAction func writeCustomData(_ sender: Any) {

        // 사용자가 입력한 비밀번호, SSID, 액세스 ID, 액세스 키를 가져온다.
        let password = passTxt.text ?? ""
        let ssid = ssidTxt.text ?? ""
        let accessId = accessIdTxt.text ?? ""
        let accessKey = accessKeyTxt.text ?? ""

        // IP 주소 표시를 초기화 한다.
        lblIp.text = ""
        let wifiData = "{\"cmd\": \"write_data\", \"ssid\":\"" + ssid + "\", \"password\": \"" + password + "\", \"access_id\":\"" + accessId + "\", \"access_key\":\"" + accessKey + "\"}"

        // 블루투스 장치의 wiriteCustomData 메서드를 호출한다.
        _ = self.bluFi?.writeCustomData([UInt8](wifiData.utf8), true).done({ (data) in
            
            // 전송된 데이터를 UTF-8로 디코딩하여 문자열로 변환한다.
            let jsonString = String(bytes: data, encoding: .utf8)
            // 디코딩된 문자열을 딕셔너리로 변환한다.
            let json = self.convertToDictionary(jsonString ?? "")
            // 딕셔너리에서 "ip" 키를 사용해 IP 주소를 가져와서 라벨에 할당한다.
            self.lblIp.text = json?["ip"] as? String
            // 전송된 데이터와 변환된 JSON을 출력한다.
            print("receive data \(data), json: \(String(describing: json))")
        })
    }
    
    @IBAction func writeCustomNullData(_ sender: Any) {
        let wifiData = "{\"cmd\": \"read_data\"}"
        
        _ = self.bluFi?.writeCustomData([UInt8](wifiData.utf8), true).done({ (data) in
            
            let jsonString = String(bytes: data, encoding: .utf8)
            let json = self.convertToDictionary(jsonString ?? "")
            
            self.lblIp.text = json?["ip"] as? String
            self.lblModel.text = json?["model"] as? String
            self.lblHwID.text = json?["hw_id"] as? String
            self.accessIdTxt.text = json?["access_id"] as? String
            self.accessKeyTxt.text = json?["access_key"] as? String
            print("receive data \(data), json: \(String(describing: json))")
        })
    }
    
    @IBAction func rebootBtn(_ sender: Any) {
        let wifiData = "{\"cmd\": \"reboot\"}"
        
        _ = self.bluFi?.writeCustomData([UInt8](wifiData.utf8), true).done({ (data) in
            
            let jsonString = String(bytes: data, encoding: .utf8)
            let json = self.convertToDictionary(jsonString ?? "")
            print("receive data \(data), json: \(String(describing: json))")
        })
    }
    
    @IBAction func exitCfgModeBtn(_ sender: Any) {
        let wifiData = "{\"cmd\": \"exit_config\"}"
        
        _ = self.bluFi?.writeCustomData([UInt8](wifiData.utf8), true).done({ (data) in
            
            let jsonString = String(bytes: data, encoding: .utf8)
            let json = self.convertToDictionary(jsonString ?? "")
            print("receive data \(data), json: \(String(describing: json))")
        })
    }
    @IBAction func ScanAndConnect(_ sender: Any) {
        scanAndConnect()
    }
}


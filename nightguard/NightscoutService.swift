//
//  ServiceBoundary.swift
//  scoutwatch
//
//  Created by Dirk Hermanns on 26.12.15.
//  Copyright © 2015 private. All rights reserved.
//

import Foundation

/* Generic Nightscout request result */
enum NightscoutRequestResult<T> {
    case data(T)
    case error(Error)
}

/* All data that is read from nightscout is accessed using this boundary. */
class NightscoutService {

    static let singleton = NightscoutService()
    
    let ONE_DAY_IN_MICROSECONDS = Double(60*60*24*1000)
    let DIRECTIONS = ["-", "↑↑", "↑", "↗", "→", "↘︎", "↓", "↓↓", "-", "-"]
    
    /* Reads the last 20 historic blood glucose data from the nightscout server. */
    @discardableResult
    func readChartData(_ resultHandler : @escaping (NightscoutRequestResult<[Int]>) -> Void) -> URLSessionTask? {
        
        // Get the current data from REST-Call
        let url = UserDefaultsRepository.getUrlWithPathAndQueryParameters(path: "api/v1/entries.json", queryParams: ["count": "20"])
        guard url != nil else {
            resultHandler(.error(createEmptyOrInvalidUriError()))
            return nil
        }

        let request = URLRequest(url: url!, cachePolicy: NSURLRequest.CachePolicy.reloadIgnoringLocalCacheData, timeoutInterval: 20) as URLRequest
        let session = URLSession.shared
        let task = session.dataTask(with: request, completionHandler: { data, response, error in
           
            dispatchOnMain { [unowned self] in
                guard error == nil else {
                    resultHandler(.error(error!))
                    return
                }
                
                guard data != nil else {
                    resultHandler(.error(self.createNoDataError(description: "No data received from Nightscout entries API")))
                    return
                }
                
                let jsonArray : [String:Any] = try!JSONSerialization.jsonObject(with: data!, options: JSONSerialization.ReadingOptions.mutableContainers) as! [String:Any]
                var sgvValues = [Int]()
                for (key, value) in jsonArray {
                   if key == "sqv" {
                        sgvValues.insert(value as! Int, at: 0)
                    }
                    resultHandler(.data(sgvValues))
                }
            }
        })
                
        task.resume()
        return task
    }
    
    func readChartData(_ resultHandler : @escaping ([Int]) -> Void) {
        self.readChartData { (result: NightscoutRequestResult<[Int]>)  in
            if case .data(let data) = result {
                resultHandler(data)
            }
        }
    }

    /* Reads the nightscout status from the backend. This is used to determine the configured
       Unit, whether it's mg/dL or mmol/l */
    @discardableResult
    func readStatus(_ resultHandler : @escaping (NightscoutRequestResult<Units>) -> Void) -> URLSessionTask? {
        
        let url = UserDefaultsRepository.getUrlWithPathAndQueryParameters(path: "api/v1/status.json", queryParams: [:])
        guard url != nil else {
            resultHandler(.error(createEmptyOrInvalidUriError()))
            return nil
        }
        let request = URLRequest(url: url!, cachePolicy: NSURLRequest.CachePolicy.reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let session = URLSession.shared
        let task = session.dataTask(with: request, completionHandler: { (data, response, error) -> Void in
            
            dispatchOnMain { [unowned self] in
                guard error == nil else {
                    resultHandler(.error(error!))
                    return
                }
                
                guard data != nil else {
                    resultHandler(.error(self.createNoDataError(description: "No data received from Nightscout status API")))
                    return
                }
                
                do {
                    let json = try JSONSerialization.jsonObject(with: data!, options: JSONSerialization.ReadingOptions.mutableContainers)
                    guard let jsonDict :NSDictionary = json as? NSDictionary else {
                        return
                    }
                    let settingsDict = jsonDict.object(forKey: "settings") as! NSDictionary
                    if (settingsDict.count > 0) {

                        let unitsAsString = settingsDict.value(forKey: "units") as! String
                        if unitsAsString.lowercased() == "mg/dl" {
                            resultHandler(.data(Units.mgdl))
                        } else {
                            resultHandler(.data(Units.mmol))
                        }
                    }
                } catch let error as NSError {
                    print(error.localizedDescription)
                    resultHandler(.error(error))
                }
            }
        })
        
        task.resume()
        return task
    }
    
    func readStatus(_ resultHandler : @escaping (Units) -> Void) {
        self.readStatus { (result: NightscoutRequestResult<Units>)  in
            if case .data(let data) = result {
                resultHandler(data)
            }
        }
    }

    /* Reads all data between two timestamps and limits the maximum return values to 400. */
    @discardableResult
    fileprivate func readChartDataWithinPeriodOfTime(oldValues : [BloodSugar], _ timestamp1 : Date, timestamp2 : Date, resultHandler : @escaping (NightscoutRequestResult<[BloodSugar]>) -> Void) -> URLSessionTask? {

        let baseUri = UserDefaultsRepository.baseUri.value
        if baseUri == "" {
            resultHandler(.error(createEmptyOrInvalidUriError()))
            return nil
        }
        
        let unixTimestamp1 : Double = timestamp1.timeIntervalSince1970 * 1000
        let unixTimestamp2 : Double = timestamp2.timeIntervalSince1970 * 1000
        
        // Get the current data from REST-Call
        let chartDataWithinPeriodOfTimeQueryParams = [
            "find[date][$gt]"   : "\(unixTimestamp1)",
            "find[date][$lte]"  : "\(unixTimestamp2)",
            "count"             : "400",
            ]
        
        let url = UserDefaultsRepository.getUrlWithPathAndQueryParameters(path: "api/v1/entries", queryParams: chartDataWithinPeriodOfTimeQueryParams)
        guard url != nil else {
            resultHandler(.error(createEmptyOrInvalidUriError()))
            return nil
        }

        let request = URLRequest(url: url!, cachePolicy: URLRequest.CachePolicy.reloadIgnoringLocalCacheData, timeoutInterval: 20)
        
        let session = URLSession.shared
        let task = session.dataTask(with: request, completionHandler: { data, response, error in
            
            guard error == nil else {
                print(error!)
                dispatchOnMain {
                    resultHandler(.error(error!))
                }
                return
            }
            
            guard data != nil else {
                print("The received data was nil...")
                dispatchOnMain { [unowned self] in
                    resultHandler(.error(self.createNoDataError(description: "No data received from Nightscout entries API")))
                    }
                return
            }
        
            let stringSgvData = String(data: data!, encoding: String.Encoding.utf8)!
            guard !stringSgvData.contains("<html") else {
                print("Invalid data with html received")  // TODO: pop an error alert
                dispatchOnMain { [unowned self] in
                    resultHandler(.error(self.createNoDataError(description: "Invalid data with HTML received from Nightscout entries API")))
                }
                return
            }

            let sgvRows = stringSgvData.components(separatedBy: "\n")
            var timestampColumn : Int = 1
            var bloodSugarColumn : Int = 2
        
            var bloodSugarArray = [BloodSugar]()
            for sgvRow in sgvRows {
                let sgvRowArray = sgvRow.components(separatedBy: "\t")
            
                if sgvRowArray.count > 2 && sgvRowArray[2] != "" {
                    // Nightscout return for some versions
                    if self.isDateColumn(sgvRowArray[1]) {
                        timestampColumn = 2
                        bloodSugarColumn = 3
                    }
                
                    if let bloodValue = Float(sgvRowArray[bloodSugarColumn]) {
                        if let bloodValueTimestamp = Double(sgvRowArray[timestampColumn]) {
                            let bloodSugar = BloodSugar(value: bloodValue, timestamp: bloodValueTimestamp)
                            bloodSugarArray.insert(bloodSugar, at: 0)
                        }
                    }
                }
            }
            
            bloodSugarArray = self.mergeInTheNewData(oldValues: oldValues, newValues: bloodSugarArray)
            dispatchOnMain {
                resultHandler(.data(bloodSugarArray))
            }
        })
        
        task.resume()
        return task
    }
    
    // append the oldvalues but leave duplicates
    fileprivate func mergeInTheNewData(oldValues : [BloodSugar], newValues : [BloodSugar]) -> [BloodSugar] {
        
        var mergedValues = oldValues
        for valueToInsert in newValues {
            
            if let index = mergedValues.firstIndex(where: { $0.timestamp > valueToInsert.timestamp }) {
                mergedValues.insert(valueToInsert, at: index)
            } else {
                // the new value is later than all other values => just append
                mergedValues.append(valueToInsert)
            }
        }
        return mergedValues
    }
    
    // appends the new value after the first value, which time is before the timestamp of newValue
    fileprivate func appendSingleValue(oldValues : [BloodSugar], newValue : BloodSugar) -> [BloodSugar] {
        
        if oldValues.count == 0 {
            return [newValue]
        }
        
        let reversedOldValues = Array(oldValues.reversed())
        var mergedValues = oldValues
        for (index, mergeValue) in reversedOldValues.enumerated() {
            if (mergeValue.timestamp < newValue.timestamp) {
                mergedValues.insert(newValue, at: index)
                return mergedValues
            }
        }
        
        return mergedValues
    }
    
    fileprivate func isDateColumn(_ cell : String) -> Bool {
        return cell.contains("-")
    }
    
    /* Reads all values from the day before. This is used for comparison with the current values. */
    @discardableResult
    func readYesterdaysChartData(_ resultHandler : @escaping (NightscoutRequestResult<[BloodSugar]>) -> Void) -> URLSessionTask? {
        
        let calendar = Calendar.current
        let yesterday = TimeService.getYesterday()
        
        let startOfYesterday = calendar.startOfDay(for: yesterday)
        let endOfYesterday = calendar.startOfDay(for: TimeService.getToday())
        
        return readChartDataWithinPeriodOfTime(oldValues: [], startOfYesterday, timestamp2: endOfYesterday, resultHandler: resultHandler)
    }
    
    func readYesterdaysChartData(_ resultHandler : @escaping ([BloodSugar]) -> Void) {
        
        self.readYesterdaysChartData { (result: NightscoutRequestResult<[BloodSugar]>)  in
            if case .data(let data) = result {
                resultHandler(data)
            }
        }
    }
    
    /* Reads all values from the current day. Beginning is 00:00 or
       the lastReceivedTime if this time is later than the current day at 00:00. */
    @discardableResult
    func readTodaysChartData(oldValues : [BloodSugar], _ resultHandler : @escaping (NightscoutRequestResult<[BloodSugar]>) -> Void) -> URLSessionTask? {
        
        let calendar = Calendar.current
        let today = TimeService.getToday()
        
        var beginOfDay = calendar.startOfDay(for: today)
        let endOfDay = calendar.startOfDay(for: TimeService.getTomorrow())
        
        // use the current time so that we have to load the new values only
        let lastReceivedTime = determineTheLatestValueOf(oldValues: oldValues)
        if lastReceivedTime > beginOfDay {
            beginOfDay = lastReceivedTime
        }
        
        return readChartDataWithinPeriodOfTime(oldValues : oldValues, beginOfDay, timestamp2: endOfDay, resultHandler: resultHandler)
    }
    
    func readTodaysChartData(oldValues : [BloodSugar], _ resultHandler : @escaping ([BloodSugar]) -> Void) {
        
        self.readTodaysChartData(oldValues: oldValues) { (result: NightscoutRequestResult<[BloodSugar]>)  in
            if case .data(let data) = result {
                resultHandler(data)
            }
        }
    }
    
    fileprivate func determineTheLatestValueOf(oldValues : [BloodSugar]) -> Date {
        if oldValues.count == 0 || oldValues.last == nil {
            return Date.init(timeIntervalSince1970: 0)
        }
        
        return Date.init(timeIntervalSince1970: oldValues.last!.timestamp / 1000)
    }
    
    @discardableResult
    func readDay(_ nrOfDaysAgo : Int, callbackHandler : @escaping (_ nrOfDay : Int, NightscoutRequestResult<[BloodSugar]>) -> Void) -> URLSessionTask? {
        let timeNrOfDaysAgo = TimeService.getNrOfDaysAgo(nrOfDaysAgo)
        
        let calendar = Calendar.current
        let startNrOfDaysAgo = calendar.startOfDay(for: timeNrOfDaysAgo)
        let endNrOfDaysAgo = startNrOfDaysAgo.addingTimeInterval(24 * 60 * 60)
        
        return readChartDataWithinPeriodOfTime(oldValues: [], startNrOfDaysAgo, timestamp2: endNrOfDaysAgo) { result in
            callbackHandler(nrOfDaysAgo, result)
        }
    }
    
    func readDay(_ nrOfDaysAgo : Int, callbackHandler : @escaping (_ nrOfDay : Int, [BloodSugar]) -> Void) {
        
        self.readDay(nrOfDaysAgo) { (nrOfDay: Int, result: NightscoutRequestResult<[BloodSugar]>)  in
            if case .data(let data) = result {
                callbackHandler(nrOfDay, data)
            }
        }
    }
    
    /* Reads all values from the last 2 Hours before. */
    @discardableResult
    func readLastTwoHoursChartData(_ resultHandler : @escaping (NightscoutRequestResult<[BloodSugar]>) -> Void) -> URLSessionTask? {
        
        let today = TimeService.getToday()
        let twoHoursBefore = today.addingTimeInterval(-60*120)
        
        return readChartDataWithinPeriodOfTime(oldValues : [], twoHoursBefore, timestamp2: today, resultHandler: resultHandler)
    }
    
    /* Reads the current blood glucose data that was planned to be displayed on a pebble watch. */
    @discardableResult
    func readCurrentDataForPebbleWatch(_ resultHandler : @escaping (NightscoutRequestResult<NightscoutData>) -> Void) -> URLSessionTask? {

        let baseUri = UserDefaultsRepository.baseUri.value
        if (baseUri == "") {
            resultHandler(.error(createEmptyOrInvalidUriError()))
            return nil
        }
        
        // Get the current data from REST-Call
        let url = UserDefaultsRepository.getUrlWithPathAndQueryParameters(path: "pebble", queryParams:[:])
        guard url != nil else {
            resultHandler(.error(createEmptyOrInvalidUriError()))
            return nil
        }
        var request : URLRequest = URLRequest(url: url!, cachePolicy: NSURLRequest.CachePolicy.reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.timeoutInterval = 70
        
        let session : URLSession = URLSession.shared
        let task = session.dataTask(with: request, completionHandler: { data, response, error in
            
            guard error == nil else {
                print("Error receiving Pepple Watch Data.")
                print(error!)
                dispatchOnMain {
                    resultHandler(.error(error!))
                }
                return
            }

            guard data != nil else {
                print("Pebble Watch Data was nil.")
                dispatchOnMain { [unowned self] in
                    resultHandler(.error(self.createNoDataError(description: "No data received from Pebble Watch API")))
                }
                return
            }

            self.extractData(data : data!, resultHandler)
        })
        
        task.resume()
        return task
    }
    
    /* Reads the current blood glucose data that was planned to be displayed on a pebble watch. */
    func readCurrentDataForPebbleWatchInBackground() {
        // Get the current data from REST-Call
        let url = UserDefaultsRepository.getUrlWithPathAndQueryParameters(path: "pebble", queryParams:[:])
        guard url != nil else {
            return
        }
        let request : URLRequest = URLRequest(url: url!, cachePolicy: NSURLRequest.CachePolicy.reloadIgnoringLocalCacheData, timeoutInterval: 20)
        
        let task = BackgroundUrlSessionWrapper.urlSession.downloadTask(with: request);
        task.resume()
    }
    
    public func extractData(data : Data, _ resultHandler : @escaping (NightscoutRequestResult<NightscoutData>) -> Void) {
        
        do {
            let json = try JSONSerialization.jsonObject(with: data, options: JSONSerialization.ReadingOptions.mutableContainers)
            guard let jsonDict :NSDictionary = json as? NSDictionary else {
                let error = NSError(domain: "PebbleWatchDataError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON received from Pebble Watch API"])
                dispatchOnMain {
                    resultHandler(.error(error))
                }
                return
            }
            let bgs = jsonDict.object(forKey: "bgs") as? NSArray
            guard bgs != nil else {
                let error = NSError(domain: "PebbleWatchDataError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON received from Pebble Watch API, missing bgs array. Check Nightscout configuration. "])
                dispatchOnMain {
                    resultHandler(.error(error))
                }
                return
            }
            if ((bgs?.count)! > 0) {
                let currentBgs : NSDictionary = bgs!.object(at: 0) as! NSDictionary
                
                let sgv : NSString = currentBgs.object(forKey: "sgv") as! NSString
                let time = currentBgs.object(forKey: "datetime") as! NSNumber
                
                let nightscoutData = NightscoutData()
                let battery : NSString? = currentBgs.object(forKey: "battery") as? NSString
                
                //Get Insulin On Board from Nightscout
                var iob : NSString? = currentBgs.object(forKey: "iob") as? NSString
                
                if battery == nil {
                    nightscoutData.battery = ""
                } else {
                    nightscoutData.battery = String(battery!) + "%"
                }
                
                //Save Insulin-On-Board data
                if iob == "0" {
                    // make iob invisible, if nothing is on board
                    iob = nil
                }
                if iob != nil {
                    nightscoutData.iob = String(iob!) + "U"
                }
                
                nightscoutData.sgv = String(sgv)
                nightscoutData.time = time
                nightscoutData.bgdeltaArrow = self.getDirectionCharacter(currentBgs.object(forKey: "trend") as! NSNumber)
                
                guard let bgdelta = Float(String(describing: currentBgs.object(forKey: "bgdelta")!))
                else {
                    nightscoutData.bgdeltaString = "?"
                    nightscoutData.bgdelta = 0
                    dispatchOnMain {
                        resultHandler(.data(nightscoutData))
                    }
                    return
                }
                nightscoutData.bgdeltaString = self.direction(bgdelta) + String(format: "%.1f", bgdelta)
                nightscoutData.bgdelta = bgdelta
                
                let cals = jsonDict.object(forKey: "cals") as? NSArray
                let currentCals = cals?.firstObject as? NSDictionary
                nightscoutData.rawbg = self.getRawBGValue(bgs: currentBgs, cals: currentCals)
                if let noiseCode = currentBgs.object(forKey: "noise") as? NSNumber {
                    nightscoutData.noise = self.getNoiseLevel(noiseCode.intValue, sgv: String(sgv))
                }
                
                dispatchOnMain {
                    resultHandler(.data(nightscoutData))
                }
            }
        } catch {
            print("Catched unknown exception.")
            let error = NSError(domain: "PebbleWatchDataError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error while extracting data from Pebble Watch API"])
            
            dispatchOnMain {
                resultHandler(.error(error))
            }
            return
        }
    }
    
    // Converts the pebbles direction number to unicode arrow characters
    fileprivate func getDirectionCharacter(_ directionNumber : NSNumber) -> String {
        
        return DIRECTIONS[directionNumber.intValue]
    }
    
    fileprivate func direction(_ delta : Float) -> String {
        if (delta >= 0) {
            return "+"
        }
        return ""
    }
    
    fileprivate func formatTime(_ secondsSince01011970 : NSNumber) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let dateString : String = timeFormatter.string(from: Date(timeIntervalSince1970: secondsSince01011970.doubleValue / 1000))
        return dateString
    }
    
    fileprivate func getNoiseLevel(_ noiseCode : Int, sgv: String) -> String {
        
        // as implemented in https://github.com/nightscout/cgm-remote-monitor/blob/d407bab2096d739708f365eae3c78847291bc997/lib/plugins/rawbg.js
        switch noiseCode {
        case 0:
            return "---"
        case 1:
            return "Clean"
        case 2:
            return "Light"
        case 3:
            return "Medium"
        case 4:
            return "Heavy"
        default:
            if UnitsConverter.toMgdl(sgv) < 40 {
                return "Heavy"
            } else {
                return "~~~"
            }
        }
    }
    
    fileprivate func getRawBGValue(bgs: NSDictionary, cals: NSDictionary?) -> String {
        
        // as implemented in https://github.com/nightscout/cgm-remote-monitor/blob/d407bab2096d739708f365eae3c78847291bc997/lib/plugins/rawbg.js
        
        let filtered: Float = (bgs.object(forKey: "filtered") as? NSNumber)?.floatValue ?? 0
        let unfiltered: Float = (bgs.object(forKey: "unfiltered") as? NSNumber)?.floatValue ?? 0
        
        let scale: Float = (cals?.object(forKey: "scale") as? NSNumber)?.floatValue ?? 0
        let slope: Float = (cals?.object(forKey: "slope") as? NSNumber)?.floatValue ?? 0
        let intercept: Float = (cals?.object(forKey: "intercept") as? NSNumber)?.floatValue ?? 0
        
        let sgv = bgs.object(forKey: "sgv") as! NSString
        let sgvmgdl: Float = UnitsConverter.toMgdl(String(sgv))
        
        var raw: Float = 0
        if slope == 0 || unfiltered == 0 || scale == 0 {
            raw = 0
        } else if filtered == 0 || sgvmgdl < 40 {
            raw = scale * (unfiltered - intercept) / slope
        } else {
            let ratio = scale * (filtered - intercept) / slope / sgvmgdl
            raw = scale * (unfiltered - intercept) / slope / ratio
        }
        
        return "\(Int(UnitsConverter.toDisplayUnits(raw.rounded())))"
    }
    
    private func createEmptyOrInvalidUriError() -> Error {
        return NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo:  [NSLocalizedDescriptionKey: "The base URI is empty or invalid!"])
    }
    
    private func createNoDataError(description: String) -> Error {
         return NSError(domain: "NightguardError", code: -1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}

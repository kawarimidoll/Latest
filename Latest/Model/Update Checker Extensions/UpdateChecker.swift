//
//  UpdateChecker.swift
//  Latest
//
//  Created by Max Langer on 07.04.17.
//  Copyright © 2017 Max Langer. All rights reserved.
//

import Foundation

/**
 Protocol that defines some methods on reporting the progress of the update checking process.
 */
protocol UpdateCheckerProgress : class {
    
	/// Indicates that the scan process has been started.
	func updateCheckerDidStartScanningForApps(_ updateChecker: UpdateChecker)

	/**
	The process of checking apps for updates has started
	- parameter numberOfApps: The number of apps that will be checked
	*/
	func updateChecker(_ updateChecker: UpdateChecker, didStartCheckingApps numberOfApps: Int)

	/// Indicates that a single app has been checked.
	func updateChecker(_ updateChecker: UpdateChecker, didCheckApp: AppBundle)

	/// Called after the update checker finished checking for updates.
	func updateCheckerDidFinishCheckingForUpdates(_ updateChecker: UpdateChecker)
	
}

/**
 UpdateChecker handles the logic for checking for updates.
 Each new method of checking for updates should be implemented in its own extension and then included in the `updateMethods` array
 */
class UpdateChecker {
    
    typealias UpdateCheckerCallback = (_ app: AppBundle) -> Void
        
	
	// MARK: - Initialization
	
	/// The shared instance of the update checker.
	static let shared = UpdateChecker()
	
	private init() {
		// Instantiate the folder listener to track changes to the Applications folder
		for url in Self.applicationURLs {
			self.folderListener = FolderUpdateListener(url: url)
			self.folderListener?.resumeTracking()
		}
		
		NotificationCenter.default.addObserver(self, selector: #selector(self.runUpdateCheck), name: .NSMetadataQueryDidFinishGathering, object: self.appSearchQuery)
	}
	
	
	// MARK: - Update Checking
	
    /// The delegate for the progress of the entire update checking progress
    weak var progressDelegate : UpdateCheckerProgress?
	
	/// The data store updated apps should be passed to
	let dataStore = AppDataStore()
    
	/// Listens for changes in the Applications folder.
    private var folderListener : FolderUpdateListener?
    
    /// The url of the /Applications folder on the users Mac
    static var applicationURLs : [URL] {
		let fileManager = FileManager.default
		let urls = [FileManager.SearchPathDomainMask.localDomainMask, .userDomainMask].flatMap { (domainMask) -> [URL] in
			return fileManager.urls(for: .applicationDirectory, in: domainMask)
		}
		
		return urls.filter { url -> Bool in
			return fileManager.fileExists(atPath: url.path)
		}
    }
    
    /// The path of the users /Applications folder
    private static var applicationPaths : [String] {
		return applicationURLs.map({ $0.path })
    }
        	
	/// The queue update checks are processed on.
	private let updateQueue = DispatchQueue(label: "UpdateChecker.updateQueue")
	
	/// The queue to run update checks on.
	private let updateOperationQueue: OperationQueue = {
		let operationQueue = OperationQueue()
		
		// Allow 100 simultanious updates
		operationQueue.maxConcurrentOperationCount = 100
		
		return operationQueue
	}()
	
	/// The metadata query that gathers all apps.
	private let appSearchQuery: NSMetadataQuery = {
		let query = NSMetadataQuery()
		query.predicate = NSPredicate(fromMetadataQueryString: "kMDItemContentTypeTree=com.apple.application")
		
		return query
	}()
    
	/// Excluded subfolders that won't be checked.
	private static let excludedSubfolders = Set(["Setapp"])
	
	/// Starts the update checking process
	func run() {
		// An update check is still ongoing, skip another round
		guard self.updateOperationQueue.operationCount == 0 || self.appSearchQuery.isStarted else {
			return
		}
                
		self.progressDelegate?.updateCheckerDidStartScanningForApps(self)
		
		// Gather all apps
		self.appSearchQuery.start()
	}
	
	@objc private func runUpdateCheck() {
		// Run metadata query to gather all apps
		let operations = self.appSearchQuery.results.compactMap { item -> Operation? in
			guard let newItem = item as? NSMetadataItem,
				let path = newItem.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
			
			let url = URL(fileURLWithPath: path)
			
			// Only allow apps in the application folder and outside excluded subfolders
			if !Self.applicationPaths.contains(where: { url.path.hasPrefix($0) }) || Self.excludedSubfolders.contains(where: { url.path.contains($0) }) {
				return nil
			}
			
			// Create an update check operation from the url if possible
			return self.updateCheckOperation(forAppAt: url)
		}

		DispatchQueue.global().async {
			self.performUpdateCheck(with: operations)
		}
	}
	
	private func updateCheckOperation(forAppAt url: URL) -> Operation? {
		// Extract version information from the app
		guard let versionInformation = self.versionInformation(forAppAt: url) else {
			return nil
		}
		
		return ([MacAppStoreUpdateCheckerOperation.self, SparkleUpdateCheckerOperation.self, UnsupportedUpdateCheckerOperation.self] as [UpdateCheckerOperation.Type]).reduce(nil) { (result, operationType) -> Operation? in
			if result == nil {
				return operationType.init(withAppURL: url, version: versionInformation.version, buildNumber: versionInformation.buildNumber, completionBlock: self.didCheck)
			}
			
			return result
		}
	}
	
	private func versionInformation(forAppAt url: URL) -> (version: String, buildNumber: String)? {
		let versionInformation: (URL) -> (version: String, buildNumber: String)? = { url in
			if let infoDict = NSDictionary(contentsOf: url.appendingPathComponent("Info").appendingPathExtension("plist")),
			   let version = infoDict["CFBundleShortVersionString"] as? String,
			   let buildNumber = infoDict["CFBundleVersion"] as? String {
					return (version, buildNumber)
			}
			
			return nil
		}
		
		// Classic macOS bundle with Contents folder containing the Info.plist
		if let info = versionInformation(url.appendingPathComponent("Contents")) {
			return (info.version, info.buildNumber)
		}

		// Wrapped iOS bundle that can run on ARM Macs
		else if let app = try? FileManager.default.contentsOfDirectory(at: url.appendingPathComponent("Wrapper"), includingPropertiesForKeys: nil).filter({ $0.pathExtension == "app" }).first,
				let info = versionInformation(app) {
			return (info.version, info.buildNumber)
		}
		
		return nil
	}
	
	private func performUpdateCheck(with operations: [Operation]) {
		assert(!Thread.current.isMainThread, "Must not be called on main thread.")
		
		// Inform delegate of update check
		DispatchQueue.main.async {
			self.progressDelegate?.updateChecker(self, didStartCheckingApps: operations.count)
		}
		
		self.dataStore.beginUpdates()

		// Start update check
		self.updateOperationQueue.addOperations(operations, waitUntilFinished: true)
			
		DispatchQueue.main.async {
			// Update Checks finished
			self.progressDelegate?.updateCheckerDidFinishCheckingForUpdates(self)
			self.appSearchQuery.stop()
		}
	}
    
    private func didCheck(_ app: AppBundle) {
		// Ensure serial access to the data store
		self.updateQueue.sync {
			self.dataStore.update(app)
			
			DispatchQueue.main.async {
				self.progressDelegate?.updateChecker(self, didCheckApp: app)
			}
		}
    }
}

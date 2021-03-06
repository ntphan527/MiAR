
//  AppDelegate.swift
//  MiAR
//
//  Created by Oscar Bonilla on 10/9/17.
//  Copyright © 2017 MiAR. All rights reserved.
//

import UIKit
import Firebase
import GoogleSignIn
import CoreLocation
import UserNotifications

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, GIDSignInDelegate {

    var window: UIWindow?
    let locationManager = CLLocationManager()
    var notesViewController: NotesViewController?
    var notes: [Note] = []
    var nearByNotes: [Note] = []
    let notificationCenter = UNUserNotificationCenter.current()
    let DEFAULTDATE = Date(timeIntervalSince1970: 0)
    var userLocation: CLLocation?
    
    let gcmMessageIDKey = "gcm.message_id"
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        FirebaseApp.configure()

        GIDSignIn.sharedInstance().clientID = FirebaseApp.app()?.options.clientID
        GIDSignIn.sharedInstance().delegate = self

        // [START set_messaging_delegate]
        Messaging.messaging().delegate = self
        Messaging.messaging().shouldEstablishDirectChannel = true
        // [END set_messaging_delegate]

        // Notification
        requestAuthorization()
        notificationCenter.delegate = self
        notificationCenter.removeAllDeliveredNotifications()
        UIApplication.shared.applicationIconBadgeNumber = 0
        application.registerForRemoteNotifications()
        
        // location manager settings
        locationManager.delegate = self
        locationManager.distanceFilter = kCLLocationAccuracyNearestTenMeters;
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestAlwaysAuthorization()
        requestUserLocation()
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.removeNote(_:)), name: Notification.Name(noteDeliveredMessageKey), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.refreshNotes(_:)), name: Notification.Name(refreshNotesMessageKey), object: nil)
        
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        if Auth.auth().currentUser != nil {
            // User is signed in.
            if let notesNC = storyboard.instantiateViewController(withIdentifier: "NotesNavigationController") as? UINavigationController {
                if let notesVC = notesNC.topViewController as? NotesViewController {
                    Note.getAllNotes(onSuccess: { (notes) in
                        print(notes)
                        self.populateNotes(notes: notes)
                        notesVC.notes = self.nearByNotes
                    }) { (error) in
                        print(error)
                    }
                    
                    notesViewController = notesVC
                    window?.rootViewController = notesNC
                    
                    // Also fill current user.
                    User.trySetCurrentUser()

                    // Each user is subscribed to its own topic.
                    print("My uid" + Auth.auth().currentUser!.uid)
                }
            }
        }
        window?.makeKeyAndVisible()
        
//        Note.listen(onSuccess: { (note) in
//            print(note)
//        }) { (error) in
//            print(error)
//        }
        
        return true
    }
    
    // Mark:- Signup/SignIn flow
    func application(_ application: UIApplication, open url: URL, options: [UIApplicationOpenURLOptionsKey : Any])
        -> Bool {
            // [END new_delegate]
            return self.application(application,
                                    open: url,
                                    // [START new_options]
                sourceApplication:options[UIApplicationOpenURLOptionsKey.sourceApplication] as? String,
                annotation: [:])
    }
    
    func application(_ application: UIApplication, open url: URL, sourceApplication: String?, annotation: Any) -> Bool {
        // [END old_delegate]
        return GIDSignIn.sharedInstance().handle(url,
                                             sourceApplication: sourceApplication,
                                             annotation: annotation)
    }
    
    // [START headless_google_auth]
    func sign(_ signIn: GIDSignIn!, didSignInFor user: GIDGoogleUser!, withError error: Error?) {
        // [START_EXCLUDE]
        // guard let controller = GIDSignIn.sharedInstance().uiDelegate as? LoginViewController else { return }
        
        // [START google_credential]
        guard let authentication = user.authentication else { return }
        let credential = GoogleAuthProvider.credential(withIDToken: authentication.idToken,
                                                       accessToken: authentication.accessToken)
        // [END google_credential]
        // [START_EXCLUDE]
        Auth.auth().signIn(with: credential) { (fbUser, error) in
            print("User signed in")
            guard let fbUser = fbUser else {
                return
            }
            User.currentUser = User(uid: fbUser.uid, username: fbUser.displayName!, email: fbUser.email!)
            User.currentUser?.save()
            
            let storyboard = UIStoryboard(name: "Main", bundle: nil)
            if let notesNC = storyboard.instantiateViewController(withIdentifier: "NotesNavigationController") as? UINavigationController {
                if let notesVC = notesNC.topViewController as? NotesViewController {
                    Note.getAllNotes(onSuccess: { (notes) in
                        print(notes)
                        self.populateNotes(notes: notes)
                        notesVC.notes = self.nearByNotes
                    }) { (error) in
                        print(error)
                    }
                    self.notesViewController = notesVC
                    self.window?.rootViewController = notesNC
                }
            }
        }
        // [END_EXCLUDE]
    }
    // [END headless_google_auth]
    
    func sign(_ signIn: GIDSignIn!, didDisconnectWith user: GIDGoogleUser!, withError error: Error!) {
        // Perform any operations when the user disconnects from app here.
    }
    
    // MARK:- Get notes
    
    @objc func refreshNotes(_ notification: Notification) {
        print("refresh notes")
        if let refreshControl = notification.userInfo?["refresh"] as? UIRefreshControl {
            Note.getAllNotes(onSuccess: { (notes) in
                print(notes)
                self.notes = []
                self.nearByNotes = []
                self.populateNotes(notes: notes)
                self.notesViewController?.notes = self.nearByNotes
                refreshControl.endRefreshing()
            }) { (error) in
                print(error)
            }
        }
    }
    
    func populateNotes(notes: [Note]) {
        let currentUserNotes = getCurrentUserNotes(notes: notes)
        self.notes = getNotesToMonitor(notes: currentUserNotes)
        
        for region in locationManager.monitoredRegions {
            locationManager.stopMonitoring(for: region)
        }
        monitorNotes()
    }
    
    func getCurrentUserNotes(notes: [Note]) -> [Note] {
        var userNotes: [Note] = []
        for note in notes {
            if !(note.delivered ?? false) {
                if note.toUser == nil || note.toUser?.email == User.currentUser?.email  {
                    userNotes.append(note)
                }
            }
        }
        return userNotes
    }
    
    // limit to 20 notes to monitor each time
    func getNotesToMonitor(notes: [Note]) -> [Note] {
        var closeByNotes: [Note] = []
        var remainingNotes: [Note] = []
        var notesToMonitor: [Note] = []
        var numOfNotes = 0
        
        for note in notes {
            let distance = NotesViewController.getNoteDistance(noteLocation: note.coordinate, userLocation: userLocation)
            print(distance)
            print(userLocation ?? "No userLocation")
            if distance < 100 {
                closeByNotes.append(note)
            } else {
                remainingNotes.append(note)
            }
        }
        
        for note in closeByNotes {
            if numOfNotes < 20 {
                notesToMonitor.append(note)
                nearByNotes.append(note)
                numOfNotes += 1
            }
        }
        
        for note in remainingNotes {
            if numOfNotes < 20 {
                notesToMonitor.append(note)
                numOfNotes += 1
            }
        }
        
        return notesToMonitor
    }
    
    @objc func removeNote(_ notification: Notification) {
        if let note = notification.userInfo?["note"] as? Note {
            stopMonitoring(note: note)
            remove(note: note)
            if note.toUser != nil {
                note.deliveryStatus(true)
            }
        }
    }
    
    // MARK:- Location handlers
    private func requestUserLocation() {
        if CLLocationManager.authorizationStatus() == .authorizedAlways{
            locationManager.startUpdatingLocation()
        } else {
            locationManager.requestAlwaysAuthorization()
        }
    }
    
    
    
    func handleEntryEvent(forRegion region: CLRegion!, notify: Bool) {
        if let note = self.note(fromRegionIdentifier: region.identifier) {
            if noteIndex(of: note, from: nearByNotes) == nil {
                nearByNotes.append(note)
                notesViewController?.notes = nearByNotes
            }
            if notify {
                print("send notification")
                scheduleLocalNotification(note)
            }
        }
    }
    
    func handleExitEvent(forRegion region: CLRegion!) {
        if let note = self.note(fromRegionIdentifier: region.identifier) {
            if let index = noteIndex(of: note, from: nearByNotes) {
                nearByNotes.remove(at: index)
                notesViewController?.notes = nearByNotes
            }
        }
    }
    
    func monitorNote(_ note: Note) {
        if noteIndex(of: note, from: notes) == nil && notes.count < 20 {
            add(note: note)
            startMonitoring(note: note)
            
            print("monitorNote")
            // TODO
            let distance = NotesViewController.getNoteDistance(noteLocation: note.coordinate, userLocation: userLocation)
            print(distance)
            print(userLocation ?? "No userLocation")
            if distance < 100 {
                let region = self.region(withNote: note)
                handleEntryEvent(forRegion: region, notify: false)
            }
        }
    }
    
    func monitorNotes() {
        for note in notes {
            startMonitoring(note: note)
        }
    }
    
    func add(note: Note) {
        notes.append(note)
    }
    
    func remove(note: Note) {
        if let indexInArray = noteIndex(of: note, from: notes) {
            notes.remove(at: indexInArray)
        }
        
        if let index = noteIndex(of: note, from: nearByNotes) {
            nearByNotes.remove(at: index)
            notesViewController?.notes = nearByNotes
        }
    }
    
    func note(fromRegionIdentifier identifier: String) -> Note? {
        let index = notes.index { $0.noteId == identifier }
        return index != nil ? notes[index!] : nil
    }
    
    func noteIndex(of note: Note, from notes: [Note]) -> Int? {
        let index = notes.index { $0.noteId == note.noteId }
        return index
    }
    
    func region(withNote note: Note) -> CLCircularRegion {
        let region = CLCircularRegion(center: note.coordinate!, radius: 100, identifier: note.noteId)
        region.notifyOnEntry = true
        region.notifyOnExit = true
        return region
    }
    
    func startMonitoring(note: Note) {
        if !CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) {
//            showAlert(withTitle:"Error", message: "Geofencing is not supported on this device!")
            return
        }
        
        if CLLocationManager.authorizationStatus() != .authorizedAlways {
//            showAlert(withTitle:"Warning", message: "Your geotification is saved but will only be activated once you grant Geotify permission to access the device location.")
        }
        
        let region = self.region(withNote: note)
        locationManager.startMonitoring(for: region)
    }
    
    func stopMonitoring(note: Note) {
        for region in locationManager.monitoredRegions {
            guard let circularRegion = region as? CLCircularRegion, circularRegion.identifier == note.noteId else { continue }
            locationManager.stopMonitoring(for: circularRegion)
        }
    }
    
    // Mark:- Notification center.
    private func requestAuthorization() {
        // Request Authorization
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { (success, error) in
            if let error = error {
                print("Request Authorization Failed (\(error), \(error.localizedDescription))")
            }
        }
    }
    
    private func scheduleLocalNotification(_ note: Note) {
        print("schedule notification")
        // Create Notification Content
        let notificationContent = UNMutableNotificationContent()
        
        // Configure Notification Content
        notificationContent.title = NSString.localizedUserNotificationString(forKey: "Incoming Message", arguments: nil)
        notificationContent.body = NSString.localizedUserNotificationString(forKey: "You have a new message!", arguments: nil)
        notificationContent.sound = UNNotificationSound.default()
        notificationContent.badge = UIApplication.shared.applicationIconBadgeNumber + 1 as NSNumber;
        
        // Set Category Identifier
        //        notificationContent.categoryIdentifier = Notification.Category.tutorial
        
        // Add Trigger
        let notificationTrigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        
        // Create Notification Request
        let notificationRequest = UNNotificationRequest(identifier: note.noteId, content: notificationContent, trigger: notificationTrigger)
        
        // Add Request to User Notification Center
        notificationCenter.add(notificationRequest) { (error) in
            if let error = error {
                print("Unable to Add Notification Request (\(error), \(error.localizedDescription))")
            }
        }
    }
    
    // [START receive_message]
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) {
        // If you are receiving a notification message while your app is in the background,
        // this callback will not be fired till the user taps on the notification launching the application.
        // TODO: Handle data of notification
        // With swizzling disabled you must let Messaging know about the message, for Analytics
        // Messaging.messaging().appDidReceiveMessage(userInfo)
        // Print message ID.
        print("received remote notification")
        
        if let messageID = userInfo[gcmMessageIDKey] {
            print("Message ID: \(messageID)")
        }
        
        // Print full message.
        print(userInfo)
    }
    
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // If you are receiving a notification message while your app is in the background,
        // this callback will not be fired till the user taps on the notification launching the application.
        // TODO: Handle data of notification
        // With swizzling disabled you must let Messaging know about the message, for Analytics
        // Messaging.messaging().appDidReceiveMessage(userInfo)
        // Print message ID.
        print("received remote notification")
        
        if let messageID = userInfo[gcmMessageIDKey] {
            print("Message ID: \(messageID)")
        }
        
        // Print full message.
        print(userInfo)
        
        completionHandler(UIBackgroundFetchResult.newData)
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Unable to register for remote notifications: \(error.localizedDescription)")
    }
    
    // This function is added here only for debugging purposes, and can be removed if swizzling is enabled.
    // If swizzling is disabled then this function must be implemented so that the APNs token can be paired to
    // the FCM registration token.
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        print("APNs token retrieved: \(deviceToken)")
        
        let token = Messaging.messaging().fcmToken
        print("FCM token: \(token ?? "")")
    
        if let currentUser = User.currentUser {
            // Subscribe to a common "miar" topic here.
            Messaging.messaging().subscribe(toTopic: "miar")
            Messaging.messaging().subscribe(toTopic: currentUser.uid)
        }
        // With swizzling disabled you must set the APNs token here.
        // Messaging.messaging().apnsToken = deviceToken
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

extension AppDelegate: CLLocationManagerDelegate {
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            locationManager.startUpdatingLocation()
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        userLocation = locations.last
        
//        print("Location Update \(userLocation?.coordinate.longitude), \(userLocation?.coordinate.latitude)")
    }
    
    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        if region is CLCircularRegion {
            print("entered region")
            handleEntryEvent(forRegion: region, notify: true)
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        if region is CLCircularRegion {
            print("exit region")
            handleExitEvent(forRegion: region)
        }
    }
    
    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        print("Monitoring failed for region with identifier: \(region!.identifier)")
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location Manager failed with the following error: \(error)")
    }
}

// [START ios_10_message_handling]
@available(iOS 10, *)
extension AppDelegate : UNUserNotificationCenterDelegate {

    // Receive displayed notifications for iOS 10 devices.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        
        print("willPresent")

        // With swizzling disabled you must let Messaging know about the message, for Analytics
        // Messaging.messaging().appDidReceiveMessage(userInfo)
        // Print message ID.
        if let messageID = userInfo[gcmMessageIDKey] {
            print("Message ID: \(messageID)")
        }

        // Print full message.
        print(userInfo)
        
        if let noteId = userInfo["noteId"] as? String {
            Note.get(withNoteId: noteId, onSuccess: { (note) in
                print("received message")
                self.monitorNote(note)
            }, onFailure: { (error) in
                print("Coulnd't get note from noteId")
            })
        }

        // Change this to your preferred presentation option
        completionHandler([.alert])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        print("didReceive")
        
        let userInfo = response.notification.request.content.userInfo
        // Print message ID.
        if let messageID = userInfo[gcmMessageIDKey] {
            print("Message ID: \(messageID)")
        }

        // Print full message.
        print(userInfo)

        completionHandler()
    }
}
// [END ios_10_message_handling]

extension AppDelegate : MessagingDelegate {
    // [START refresh_token]
    func messaging(_ messaging: Messaging, didRefreshRegistrationToken fcmToken: String) {
        print("Firebase registration token: \(fcmToken)")
    }
    // [END refresh_token]
    // [START ios_10_data_message]
    // Receive data messages on iOS 10+ directly from FCM (bypassing APNs) when the app is in the foreground.
    // To enable direct data messages, you can set Messaging.messaging().shouldEstablishDirectChannel to true.
    func messaging(_ messaging: Messaging, didReceive remoteMessage: MessagingRemoteMessage) {
        print("Received data message: \(remoteMessage.appData)")
    }
    // [END ios_10_data_message]
}

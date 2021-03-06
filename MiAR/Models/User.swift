//
//  User.swift
//  MiAR
//
//  Created by Phan, Ngan on 10/15/17.
//  Copyright © 2017 MiAR. All rights reserved.
//

import UIKit
import Firebase

class User: NSObject {
    // Firebase path: "users/\(uid)"
    //
    // These are generated by FirebaseAuth. See AppDelegate.swift for more details.
    var uid: String
    
    var username: String
    var email: String
    
    init(uid: String, username: String, email: String) {
        self.uid = uid
        self.username = username
        self.email = email
    }
    
    static func initWithSnapshot(snap: DataSnapshot) -> User {
        let value = snap.value as? NSDictionary
        let username = value?["username"] as? String ?? ""
        let email = value?["email"] as? String ?? ""
        return User.init(uid: snap.key, username: username, email: email)
    }
    
    static var currentUser: User?
    
    func save() {
        let ref = Database.database().reference()
        ref.child("users/\(self.uid)/username").setValue(username)
        ref.child("users/\(self.uid)/email").setValue(email)
    }
    
    static func trySetCurrentUser() {
        if Auth.auth().currentUser != nil {
            User.get(withUid: Auth.auth().currentUser!.uid, onSuccess: { (user) in
                User.currentUser = user
            }, onFailure: { (error) in
                print("Error getting current user")
            })
        }
    }
    
    static func get(withUid uid: String, onSuccess: @escaping (User)->(), onFailure: @escaping (Error)->()) {
        let ref = Database.database().reference()
        ref.child("users").child(uid).observeSingleEvent(of: .value, with: { (snapshot) in
            onSuccess(User.initWithSnapshot(snap: snapshot))
        }) { (error) in
            print(error.localizedDescription)
            onFailure(error)
        }
    }
    
    /*
     Example usage:
     
         User.getAllUsers(onSuccess: { (users) in
             print("Got all users")
             print(users[0].email)
         }) { (error) in
             print("Errored out")
         }
     */
    static func getAllUsers(onSuccess: @escaping ([User])->(), onFailure: @escaping (Error)->()) {
        let ref = Database.database().reference()
        let allUsersQuery = ref.child("users").queryOrderedByKey()
        allUsersQuery.observeSingleEvent(of: .value, with: { (snapshot) in
            // Get user value
            var users: [User] = []
            for child in snapshot.children {
                print(child)
                if let snap = child as? DataSnapshot {
                    users.append(User.initWithSnapshot(snap: snap))
                }
            }
            onSuccess(users)
        }) { (error) in
            print(error.localizedDescription)
            onFailure(error)
        }
    }
}

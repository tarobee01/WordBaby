import Foundation
import Combine
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import SwiftUI

@MainActor
class AuthViewModel: ObservableObject {
    private let authService = AuthService()

    private let db = Firestore.firestore()
    @Published var isAuthenticated: Bool? = nil {
        didSet {
            if self.isAuthenticated == false {
                reset()
                NotificationCenter.default.post(name: .authStateChanged, object: nil)
            }
        }
    }

    private var listener: AuthStateDidChangeListenerHandle?
    
    //currentuser情報
    @Published var user: User?
    @Published var userProfile: UserProfile?
    
    @Published var isCreateAccountError = false
    @Published var isSignInError = false
    @Published var signInProcess: SignInProcess = .sleep
    @Published var createAccountProcess: CreateAccountProcess = .sleep
    @Published var createAccountError: Error? {
        didSet {
            isCreateAccountError = createAccountError != nil
        }
    }
    @Published var signInError: Error? {
        didSet {
            isSignInError = signInError != nil
        }
    }
    
    init() {
        listener = Auth.auth().addStateDidChangeListener { [weak self] _, firebaseUser in
            self?.isAuthenticated = firebaseUser != nil
            self?.user = firebaseUser.map(User.init(from:))
        }
    }
    
    func reset() {
            user = nil
            userProfile = nil
            isCreateAccountError = false
            isSignInError = false
            signInProcess = .sleep
            createAccountProcess = .sleep
            createAccountError = nil
            signInError = nil
        print("AuthVmdata was cleared")
        }
    
    //サインイン
    func signInAndErrorHandling(email: String, password: String) {
        Task {
            signInProcess = .working
            do {
                try await authService.signIn(email: email, password: password)
                signInProcess = .success
                try await getUserProfile()
            } catch {
                print("Debug: error occured while signin/Error: \(error)")
                self.signInError = error
                signInProcess = .failed(error)
            }
        }
    }
    
    //サインアウト
    func signOutAndErrorHandling() {
        do {
            try authService.signOut()
        } catch {
            print("Debug: error occured while singout/Error\(error)")
        }
    }
    
    //アカウントを作成
    func createAccountAndErrorHandling(name: String, email: String, password: String) {
        Task {
            createAccountProcess = .working
            do {
                //firebaseAuthにアカウントを登録
                let result = try await Auth.auth().createUser(withEmail: email, password: password)
                //Authのdisplaynameを更新
                let changeRequest = result.user.createProfileChangeRequest()
                            changeRequest.displayName = name
                            try await changeRequest.commitChanges()
                
                createAccountProcess = .success
                //fireStoreにユーザー情報を登録
                try await createUserProfile(uid: result.user.uid, name: name, description: "description", email: email)
                //fireStoreからuser情報をfetchする
                try await getUserProfile()
            } catch {
                print("Debug: error occured while creating account: \(error)")
                self.createAccountError = error
                createAccountProcess = .failed(error)
            }
        }
    }
    
    //firestoreにユーザーを登録する
    func createUserProfile(uid: String, name: String, description: String, email: String) async throws {
        let db = Firestore.firestore()
        try await db.collection("users").document(uid).setData([
            "name": name,
            "description": description,
            "imageUrl": "https://firebasestorage.googleapis.com/v0/b/swiftsnspractice.appspot.com/o/no_image_square.jpg?alt=media&token=f7256579-130a-4345-9882-e976f3fdf254",
            "email" : email,
            "id": uid,
            "following": [],
            "followedBy": [],
            "vocabulary": self.defaultVocabulary
        ])
    }
    //プロフィールをゲットする
    func getUserProfile() async throws{
        guard let uid = Auth.auth().currentUser?.uid else { return }
        
        let db = Firestore.firestore()
        do {
            let documentSnapshot = try await db.collection("users").document(uid).getDocument()
            if let userProfile = try? documentSnapshot.data(as: UserProfile.self) {
                // userProfileに成功してキャストした場合
                self.userProfile = userProfile
            } else {
                // ドキュメントは存在するが、UserProfileにキャストできない場合
                print("Document exists, but could not be cast to UserProfile")
            }
        } catch {
            // ドキュメントの取得に失敗した場合
            print("Error fetching user profile: \(error.localizedDescription)")
        }
    }
    
    //アカウント消去
    func deleteUser() {
        Task {
            do {
                if let uid = Auth.auth().currentUser?.uid {
                    do {
                        try await db.collection("users").document(uid).delete()
                    } catch {
                        print("Debug:: Error occured while deleteing document in users/Error:: \(error.localizedDescription)")
                    }
                }
                try await authService.deleteUser()
            } catch {
                print("Debug:: Error occured while deleting user/Error\(error.localizedDescription)")
            }
        }
    }
    

    
    func setUserProfile(name: String, description: String, inputImage: UIImage) {
        guard let currentUser = Auth.auth().currentUser else { return }
        let uid = currentUser.uid
        // Firebase Storageに画像をアップロード
        let storage = Storage.storage()
        let storageRef = storage.reference()
        let imagesRef = storageRef.child("userImages\(uid)")

        if let imageData = inputImage.jpegData(compressionQuality: 0.8) {
           imagesRef.putData(imageData, metadata: nil) { (metadata, error) in
               guard metadata != nil else {
                    print("Debug:: cannot find metadata in AuthViewModel/setUserProfile")
                    return
                }
                // You can also access to download URL after upload.
                imagesRef.downloadURL { (url, error) in
                    guard let downloadURL = url else {
                        print("Debug:: cannot download imageURL in AuthViewModel/setUserProfile")
                        return
                    }
                    //URLを文字列に変換
                    let stUrl = downloadURL.absoluteString
                    // Firestore用のオブジェクトを作成
                    let db = Firestore.firestore()
                    let newProfileData: [String: Any] = [
                        "name": name,
                        "description": description,
                        "imageUrl": stUrl, // このURLは後で更新します
                        "id": uid
                    ]
                    // Firestoreのuser情報を更新する
                    db.collection("users").document(uid).updateData(newProfileData) { error in
                        if let error = error {
                            print("Debug: Cannot update Firestore data in AuthViewModel/setUserProfile/firestoreのuser情報を更新する: Error: \(error.localizedDescription)")
                        } else {
                            // ビューモデルのデータを更新
                            self.userProfile?.name = name
                            self.userProfile?.description = description
                            self.userProfile?.imageUrl = stUrl
                            // FirebaseAuthのdisplayNameを更新
                            let changeRequest = currentUser.createProfileChangeRequest()
                            changeRequest.displayName = name
                            changeRequest.commitChanges { error in
                                if let error = error {
                                    print("Debug:: displayNameの更新中にエラーが発生しました。/Error:: \(error.localizedDescription)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    func changeUsersPassword(newPass: String) async throws {
        guard let currentUser = authService.auth.currentUser else {
            print("Debug:: Cannnot get currentUser while changing password")
            throw AuthError.currentUserNotFound
        }
        try await currentUser.updatePassword(to: newPass)
    }
    
    func changeUsersEmail(newEmail: String) async throws {
        guard let currentUser = Auth.auth().currentUser else {
            print("Debug:: Cannot get currentUser while changing email")
            return
        }
        //firebaseAuthのemailを変更する
        try await currentUser.sendEmailVerification(beforeUpdatingEmail: newEmail)
        
        //firestoreのユーザープロフィールのemailを変更する
        let userUid = currentUser.uid
        let db = Firestore.firestore()
        try await db.collection("users").document(userUid).updateData([
            "email" : newEmail
        ])
    }
    //トグルフォロー
    func toggleFollow(currentUserId: String, targetUserId: String) async {
        if currentUserId == "no id" {
            print("Debug:: currentUserID is no id in AuthViewModel/toggleFollow")
            return
        }
        
        let db = Firestore.firestore()
        let currentUserRef = db.collection("users").document(currentUserId)
        let targetUserRef = db.collection("users").document(targetUserId)

        do {
            // 自分のドキュメントを取得
            let currentUserSnapshot = try await currentUserRef.getDocument()
            if let currentUser = currentUserSnapshot.data(), let following = currentUser["following"] as? [String] {
                // すでにフォローしているか確認
                if following.contains(targetUserId) {
                    // フォローを解除
                    try await currentUserRef.updateData([
                        "following": FieldValue.arrayRemove([targetUserId])
                    ])
                    try await targetUserRef.updateData([
                        "followedBy": FieldValue.arrayRemove([currentUserId])
                    ])
                    
                    //ビューモデルのuserProfileを更新
                    self.userProfile?.following.removeAll(where: { $0 == targetUserId })
                } else {
                    // フォローする
                    try await currentUserRef.updateData([
                        "following": FieldValue.arrayUnion([targetUserId])
                    ])
                    try await targetUserRef.updateData([
                        "followedBy": FieldValue.arrayUnion([currentUserId])
                    ])
                    
                    //ビューモデルのuserProfileを更新
                    self.userProfile?.following.append(targetUserId)
                }
            }
            
            //ビューモデルのuserProfileを変更する

        } catch {
            print("Error toggling follow status: \(error.localizedDescription)")
        }
    }
    
    //vocabularyに追加する
    func addWordsToVocabulary(words: [String]) async -> Bool{
        //firestoreに追加
        let db = Firestore.firestore()
        if let uid = Auth.auth().currentUser?.uid {
            do {
                let document = try await db.collection("users").document(uid).getDocument()
                if let existingVocabulary = document.data()?["vocabulary"] as? [String] {
                    // 既存の単語と重複しないように新しい単語を追加
                    let updatedVocabulary = Array(Set(existingVocabulary).union(words))
                    try await db.collection("users").document(uid).updateData(["vocabulary": updatedVocabulary])
                    //ビューモデルを変更
                    self.userProfile?.vocabulary = updatedVocabulary
                    return true
                } else {
                    print("Debug:: cannot get existingVocabulary in AuthViewModel/addWordsToVocabulary")
                    return false
                }
            } catch {
                print("Debug::Error adding words to vocabulary in AuthViewModel/addWordsToVocabulary/Error::\(error)")
                return false
            }
        } else {
            print("Debug:: cannot get currentUserId in AuthViewModel/addWordsToVocabulary")
            return false
        }
    }
    
    //vocabularyからリストの単語を消去する
    func removeWordFromVocabulary(word: String) async -> Bool {
        let db = Firestore.firestore()
        if let uid = Auth.auth().currentUser?.uid {
            do {
                let document = try await db.collection("users").document(uid).getDocument()
                if var existingVocabulary = document.data()?["vocabulary"] as? [String] {
                    // 単語が存在すれば削除
                    if let index = existingVocabulary.firstIndex(of: word) {
                        existingVocabulary.remove(at: index)
                        try await db.collection("users").document(uid).updateData(["vocabulary": existingVocabulary])
                        // ビューモデルを更新
                        self.userProfile?.vocabulary = existingVocabulary
                        return true
                    } else {
                        print("Debug:: Word not found in vocabulary in AuthViewModel/removeWordFromVocabulary")
                        return false
                    }
                } else {
                    print("Debug:: Cannot get existing vocabulary in AuthViewModel/removeWordFromVocabulary")
                    return false
                }
            } catch {
                print("Debug:: Error removing word from vocabulary in AuthViewModel/removeWordFromVocabulary/Error::\(error)")
                return false
            }
        } else {
            print("Debug:: Cannot get current user ID in AuthViewModel/removeWordFromVocabulary")
            return false
        }
    }

    
    let defaultVocabulary: [String] = [
            ///　書き言葉バージョン
            // 格助詞
            "が", "の", "を", "に", "へ", "と", "で", "から", "より",
            // 並立助詞
            "や", "と", "に", "か", "なり", "だの",
            // 係助詞
            "は", "も", "こそ", "でも", "しか", "さえ", "など",
            // 副助詞
            "ばかり", "まで", "だけ", "ほど", "なら", "くらい", "ぐらい",
            // 終助詞
            "か", "よ", "ね", "な", "わ", "さ", "ぜ", "けれども", "けど",
            // 接続助詞
            "て",
            // 助動詞
            // です、ます形
            "ます", "ません", "ました", "ませんでした", "ませば", "ましょう", "です", "まし", "でし", "まし",
            // た形
            "た", "たら",
            // ない形
            "ない", "なかろう", "なく", "なかった", "なければ", "なかれ", "なかっ",
            // たい形
            "たい", "たかろう", "たく", "たかった", "たければ",
            // れる・られる形
            "れる", "られる", "れた", "れれば",
            // せる・させる形
            "せる", "させる", "せた", "せれば",
            // できる形
            "できる", "できた", "できれば", "でき",
            // だろう・でしょう形
            "だろう", "でしょう",
            // なる形
            "なる", "なら", "なった", "なれ", "なれば", "なっ",
            // べき・べく形
            "べき", "べく", "べけれ",
            // ず形
            "ず", "ぬ", "ずば",
            // う・おう形
            "う", "おう", "おった", "えば",
            // こと・もの形
            "こと", "もの",
            // 断定のだ
            "だ", "だっ",
            // 感動詞
            "え", "ああ", "おお", "うわあ", "わあ","へえ",
            // 基本動詞
            "ある","あっ","ない","なっ",
            "する", "し", "いる", "い", "くる", "き",
            // ??
            "とっ", "ぶり",
            ///　口語バージョン
            "ちゃう", "じゃん", "っす", "っけ", "って", "すぎる", "んだ", "んだよ", "っちゃう", "ったら", "っぽい", "ねえ", "よね", "だよ", "じゃない", "のー", "てる", "ー", "よー"
    ]
}

extension User {
    init(from firebaseUser: FirebaseAuth.User) {
            self.id = firebaseUser.uid
            self.name = firebaseUser.displayName ?? "no name"
        }
}

enum AuthError: Error {
    case currentUserNotFound
}

extension Notification.Name {
    static let authStateChanged = Notification.Name("authStateChanged")
}


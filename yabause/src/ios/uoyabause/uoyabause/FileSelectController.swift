//
//  FileSelectController.swift
//  uoyabause
//
//  Created by MiyamotoShinya on 2016/08/27.
//  Copyright © 2016年 devMiyax. All rights reserved.
//

import Foundation
import SwiftUI
import UIKit
import Kingfisher
#if FREE_VERSION
import GoogleMobileAds
#endif

class GameItemCell: UICollectionViewCell {
    let titleLabel = UILabel()
    let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .defaultBackground
        contentView.backgroundColor = .defaultBackground
        setupViews()
        setupConstraints()
        updateColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isSelected: Bool {
        didSet {
            contentView.backgroundColor = isSelected ? UIColor.selectedBackground : UIColor.defaultBackground
        }
    }

    // ダークモード変更時の処理
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        if #available(iOS 13.0, *) {
            if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
                updateColors()
            }
        }
    }

    // 色の更新
    private func updateColors() {
        backgroundColor = .defaultBackground
        contentView.backgroundColor = isSelected ? UIColor.selectedBackground : UIColor.defaultBackground

        titleLabel.textColor = .adaptiveTextColor
    }

    private func setupViews() {
        // ImageViewの設定
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)

        // TitleLabelの設定
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2  // 最大2行に制限
        titleLabel.lineBreakMode = .byTruncatingTail  // 超過分は省略
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.systemFont(ofSize: 14)
        contentView.addSubview(titleLabel)
    }

    private func setupConstraints() {
        // ImageViewの制約
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.heightAnchor.constraint(equalToConstant: 100)
        ])

        // TitleLabelの制約
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)

        ])
    }
}


/// In-game disc picker.
///
/// Since the SwiftUI home screen (MainTabView) replaced the legacy
/// MainScreenController, this controller is only presented modally from
/// GameViewController's "Change Disk" flow. It is always used with
/// `isStandalone = true` and a `completionHandler`; it is never embedded
/// as a child view controller any more.
class FileSelectController : UIViewController, UICollectionViewDataSource, UICollectionViewDelegate,UICollectionViewDelegateFlowLayout, UISearchBarDelegate, UISearchResultsUpdating {

#if FREE_VERSION
    var bannerView: GADBannerView!
#endif

    var file_list: [GameInfo] = []
    var filteredFiles: [GameInfo] = []
    var selected_file_path: String = ""
    var productNumber: String = ""
    var columns = 3.0
    var searchController: UISearchController!
    var collectionView: UICollectionView!

    var completionHandler: ((String?) -> Void)?

    var activityIndicator: UIActivityIndicatorView!
    var blurEffectView: UIVisualEffectView!
    var isStandalone: Bool = false

#if FREE_VERSION
    func addBannerViewToView(_ bannerView: GADBannerView) {
        bannerView.translatesAutoresizingMaskIntoConstraints = false
        bannerView.backgroundColor = .defaultBackground
        view.addSubview(bannerView)
        view.addConstraints(
          [NSLayoutConstraint(item: bannerView,
                              attribute: .bottom,
                              relatedBy: .equal,
                              toItem: view.safeAreaLayoutGuide,
                              attribute: .bottom,
                              multiplier: 1,
                              constant: 0),
           NSLayoutConstraint(item: bannerView,
                              attribute: .centerX,
                              relatedBy: .equal,
                              toItem: view,
                              attribute: .centerX,
                              multiplier: 1,
                              constant: 0)
          ])
       }

#endif


    func setupCollectionViewLayout(columns: CGFloat) {
        self.columns = columns
        let layout = UICollectionViewFlowLayout()
        layout.sectionInset = UIEdgeInsets(top: 6, left: 0, bottom: 0, right: 0) // 上に6ptの余裕
        let spacing: CGFloat = 10 // アイテム間のスペース
        let totalSpacing = spacing * (columns - 1) + 20 // 合計のスペース
        let width = (view.frame.width - totalSpacing) / columns
        layout.itemSize = CGSize(width: width, height: width)
        layout.minimumLineSpacing = 18 // フォーカス表示のために行間を広く設定
        layout.minimumInteritemSpacing = spacing
        collectionView.collectionViewLayout = layout
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in
            // デバイスの向きに応じて列数を調整
            if UIDevice.current.orientation.isLandscape {
                self.columns = 5
                // 横画面の時は4列
                self.setupCollectionViewLayout(columns: 5)
            } else {
                self.columns = 3
                // 縦画面の時は3列
                self.setupCollectionViewLayout(columns: 3)
            }
            self.collectionView.reloadData()
        }, completion: nil)
    }

    let searchBar = UISearchBar()

    override func viewDidAppear(_ animated: Bool) {
        updateDoc()
    }

    override func viewDidLoad(){
        super.viewDidLoad()

        // 背景色を設定（システムのモードに応じて）
        view.backgroundColor = .defaultBackground

        // デリゲートとデータソースの設定
        let layout = UICollectionViewFlowLayout()
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.delegate = self
        collectionView.dataSource = self
        collectionView.backgroundColor = .defaultBackground
        collectionView.register(GameItemCell.self, forCellWithReuseIdentifier: "GameItemCell")
        collectionView!.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "files")


        searchBar.delegate = self
        searchBar.placeholder = NSLocalizedString("Search", comment: "Search placeholder text")
        searchBar.barTintColor = .defaultBackground
        searchBar.backgroundColor = .defaultBackground

        // UISearchBar と UICollectionView を UIStackView に追加
        let stackView = UIStackView(arrangedSubviews: [searchBar, collectionView])
            stackView.axis = .vertical
            stackView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(stackView)

            // Auto Layout constraints
            NSLayoutConstraint.activate([
                stackView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                stackView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
            ])


        // デバイスの向きに応じて列数を調整
        if UIDevice.current.orientation.isLandscape {
            // 横画面の時は4列
            self.setupCollectionViewLayout(columns: 5)
        } else {
            // 縦画面の時は3列
            self.setupCollectionViewLayout(columns: 3)
        }

        // Blur Effect Viewの設定
        let blurEffect = UIBlurEffect(style: .dark)
        blurEffectView = UIVisualEffectView(effect: blurEffect)
        blurEffectView.frame = self.view.bounds
        blurEffectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blurEffectView.isHidden = true
        self.view.addSubview(blurEffectView)

        // Activity Indicatorの設定
        activityIndicator = UIActivityIndicatorView(style: .large)
        activityIndicator.center = self.view.center
        activityIndicator.hidesWhenStopped = true
        self.view.addSubview(activityIndicator)

#if FREE_VERSION
        // A subscriber paid to be rid of ads. Wrapping rather than returning:
        // this runs partway through view setup and the rest still has to.
        if ProEntitlement().showsAds {
            let viewWidth = view.frame.inset(by: view.safeAreaInsets).width

            // Here the current interface orientation is used. Use
            // GADLandscapeAnchoredAdaptiveBannerAdSizeWithWidth or
            // GADPortraitAnchoredAdaptiveBannerAdSizeWithWidth if you prefer to load an ad of a
            // particular orientation,
            let adaptiveSize = GADCurrentOrientationAnchoredAdaptiveBannerAdSizeWithWidth(viewWidth)
            bannerView = GADBannerView(adSize: adaptiveSize)
            bannerView.backgroundColor = .defaultBackground


            addBannerViewToView(bannerView)

            // Load adUnitID from secrets.plist (not committed to git)
            // For testing, use Google's test banner ad unit ID
            if let path = Bundle.main.path(forResource: "secrets", ofType: "plist"),
               let dict = NSDictionary(contentsOfFile: path) as? [String: AnyObject],
               let bannerId = dict["bannerId"] as? String {
                bannerView.adUnitID = bannerId
            } else {
                // Google's test ad unit ID for development
                // See: https://developers.google.com/admob/ios/test-ads
                bannerView.adUnitID = "ca-app-pub-3940256099942544/2934735716"
            }


            let bannerHeight = bannerView.frame.height
            let safeAreaHeight = view.safeAreaLayoutGuide.layoutFrame.height
            let newGameVCHeight = safeAreaHeight - bannerHeight

            // Adjust the height of gameVC
            collectionView?.frame.size.height = newGameVCHeight

            bannerView.rootViewController = self
            bannerView.delegate = self

            bannerView.load(GADRequest())
        }
#endif

        // Activity Indicatorをビュー階層の一番上に持ってくる
        self.view.bringSubviewToFront(activityIndicator)
        if( isStandalone ){
            setupNavigationBar()
        }
    }

    private func setupNavigationBar() {
        let closeButton = UIBarButtonItem(title: NSLocalizedString("Close", comment: "Close Dialoig"), style: .plain, target: self, action: #selector(closeButtonTapped))
        self.view.backgroundColor = .defaultBackground
        navigationItem.leftBarButtonItem = closeButton
        title = NSLocalizedString("Change Disk", comment: "Chnge the game disk")
    }

    @objc private func closeButtonTapped() {
        dismiss(animated: true) {
            self.completionHandler?(nil)
        }
    }

    // UISearchBarDelegate methods
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        if searchText.isEmpty {
            filteredFiles = file_list
        } else {
            filteredFiles = file_list.filter { ($0.displayName ?? "").localizedCaseInsensitiveContains(searchText) }
        }
        collectionView.reloadData()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        // Search button clicked
        searchBar.resignFirstResponder()
    }


    func updateSearchResults(for searchController: UISearchController) {
        let searchText = searchController.searchBar.text ?? ""
        if searchText.isEmpty {
            filteredFiles = file_list
        } else {
            filteredFiles = file_list.filter { ($0.displayName ?? "").localizedCaseInsensitiveContains(searchText) }
        }
        collectionView.reloadData()
    }


    func numberOfSections(in collectionView: UICollectionView) -> Int {
        return 1
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return filteredFiles.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "GameItemCell", for: indexPath) as! GameItemCell
        let gameInfo = filteredFiles[indexPath.row]
        cell.titleLabel.text = gameInfo.displayName

        // セルの色を更新（GameItemCellのupdateColorsメソッドで処理）

        // Kingfisherを使用して画像を設定
        if let imageUrl = gameInfo.imageUrl, let url = URL(string: imageUrl) {
            cell.imageView.kf.setImage(with: url, placeholder: UIImage(named: "missing"))
        }
        return cell
    }

    func calculateCellHeight(for indexPath: IndexPath) -> CGFloat {
        let gameInfo = filteredFiles[indexPath.row]
        if let text = gameInfo.displayName{
            let attributes = [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14)]

            let spacing: CGFloat = 10 // アイテム間のスペース
            let totalSpacing = spacing * (columns - 1) + 20 // 合計のスペース
            let width = (view.frame.width - totalSpacing) / columns

            let size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            let options = NSStringDrawingOptions.usesFontLeading.union(.usesLineFragmentOrigin)
            let estimatedRect = NSString(string: text).boundingRect(with: size, options: options, attributes: attributes, context: nil)
            return estimatedRect.height + 20 + 100// テキストの上下にマージンを追加
        }else{
            return 120
        }
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        // アイテムのサイズを設定
        let spacing: CGFloat = 10 // アイテム間のスペース
        let totalSpacing = spacing * (columns - 1) + 20 // 合計のスペース
        let width = (view.frame.width - totalSpacing) / columns

        // 固定の高さを使用（画像100 + タイトル2行分約50 + マージン10）
        // これにより同じ行の全セルが同じ高さになり、画像の位置が揃う
        let fixedHeight: CGFloat = 160
        return CGSize(width: width, height: fixedHeight)
    }

    func addSkipBackupAttributeToItemAtURL(url: URL) throws {
        var url = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try url.setResourceValues(resourceValues)
    }

    func excludeDirectoryFromBackup(directoryURL: URL) throws {
        try addSkipBackupAttributeToItemAtURL(url: directoryURL)

        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(at: directoryURL, includingPropertiesForKeys: nil)

        while let fileURL = enumerator?.nextObject() as? URL {
            try addSkipBackupAttributeToItemAtURL(url: fileURL)
        }
    }

    func getAllFilesRecursively(atPath path: String, manager: FileManager) -> [String] {
        var allFiles: [String] = []
        do {
            let contents = try manager.contentsOfDirectory(atPath: path)
            for item in contents {
                let fullPath = (path as NSString).appendingPathComponent(item)
                var isDir: ObjCBool = false
                if manager.fileExists(atPath: fullPath, isDirectory: &isDir) {
                    if isDir.boolValue {
                        // If it's a directory, recurse into it
                        allFiles.append(contentsOf: getAllFilesRecursively(atPath: fullPath, manager: manager))
                    } else {
                        // If it's a file, add it to the list
                        allFiles.append(fullPath)
                    }
                }
            }
        } catch {
            print("Error reading contents of directory: \(error)")
        }
        return allFiles
    }

    /// Drops the games the free version may not play.
    ///
    /// The same three games the games tab unlocks, decided by the same type:
    /// this used to keep whichever three the directory walk happened to reach
    /// first, so the disc picker could offer a game the library showed as
    /// locked. Nothing is presented from here - this runs on the scan's
    /// background queue, and the gate belongs to the tap that hits the limit.
    func playableOnly(_ files: [GameInfo]) -> [GameInfo] {
        guard let unlocked = FreeGameSlots.unlockedPaths(items: GameListCache().load())
        else { return files }
        return files.filter { file in
            guard let path = file.filePath else { return false }
            return unlocked.contains(path)
        }
    }

    func updateDoc(){

        self.view.bringSubviewToFront(activityIndicator)
        blurEffectView.isHidden = false
        activityIndicator.startAnimating()

        // ドキュメントディレクトリをバックアップ対象外にする
        do {
            let documentsDirectory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            try self.excludeDirectoryFromBackup(directoryURL: documentsDirectory)
        } catch {
            print("Error excludiong directory")
        }

        DispatchQueue.global(qos: .userInitiated).async {

            self.file_list.removeAll()
            let manager = FileManager.default
            let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] as String

            var count=0
            let all_file_list = self.getAllFilesRecursively(atPath: documentsPath, manager: manager)
            for path in all_file_list {
                print(path)
                var isDir: ObjCBool = false
                if manager.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue {

                    do {

                        // 拡張子がCHDの場合は、CHDからゲーム情報を取得
                        if path.hasSuffix(".chd") {
                            if let buf = getGameinfoFromChd(path) {
                                let data = Data(bytes: buf, count: 256)
                                if let gi = getGameInfoFromBuf(filePath: path, header: data) {
                                    self.file_list.append(gi)
                                }
                            }
                        }

                        // in the case of cue file
                        if path.hasSuffix(".cue") {
                            if let gi = try genGameInfoFromCUE(filePath: path) {
                                self.file_list.append(gi)
                            }
                        }

                        // in the case of ccd file
                        if path.hasSuffix(".ccd") {
                            if let gi = try genGameInfoFromCCD(filePath: path) {
                                self.file_list.append(gi)
                            }
                        }

                        // in the case of ccd file
                        if path.hasSuffix(".mds") {
                            if let gi = try genGameInfoFromMDS(filePath: path) {
                                self.file_list.append(gi)
                            }
                        }

                    }catch GameInfoError.isoFileNotFound(let message) {

                        print(message)

                        DispatchQueue.main.async {
                            // アラートを表示
                            let alert = UIAlertController(
                                title: NSLocalizedString("Error", comment: "Title for the error alert"),
                                message: message,
                                preferredStyle: .alert
                            )

                            let okAction = UIAlertAction(
                                title: NSLocalizedString("OK", comment: "Default action button title"),
                                style: .default,
                                handler: nil
                            )
                            
                            alert.addAction(okAction)
                            // ゲームパッド対応: デフォルトアクションを設定
                            alert.preferredAction = okAction

                            self.present(alert, animated: true, completion: nil)
                        }

                    } catch {
                        print("An unexpected error occurred: \(error).")
                    }


                }
            }
            self.file_list = self.playableOnly(self.file_list)
            self.file_list.sort { $0.displayName ?? "" < $1.displayName ?? "" }
            self.filteredFiles = self.file_list

            // UIの更新をメインスレッドで実行
            DispatchQueue.main.async { [weak self] in
                self?.collectionView.reloadData() // collectionViewのデータをリロード
                self?.blurEffectView.isHidden = true
                self?.activityIndicator.stopAnimating()
            }

        }

    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if self.isBeingDismissed {
            completionHandler?(nil)
        }
    }


    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {

        selected_file_path = filteredFiles[(indexPath as NSIndexPath).row].filePath!
        productNumber = filteredFiles[(indexPath as NSIndexPath).row].productNumber!

        // The only remaining caller is the in-game "Change Disk" flow, which
        // always installs a completionHandler. Without one there is nothing
        // to report the selection to, so the tap is simply ignored.
        if( completionHandler != nil ){
            completionHandler?(selected_file_path)
            dismiss(animated: true, completion: nil)
        }
    }


    func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) {
        let cell = collectionView.cellForItem(at: indexPath)
        UIView.animate(withDuration: 0.2) {
            cell?.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
        }
    }

    func collectionView(_ collectionView: UICollectionView, didUnhighlightItemAt indexPath: IndexPath) {
        let cell = collectionView.cellForItem(at: indexPath)
        UIView.animate(withDuration: 0.2) {
            cell?.transform = .identity
        }
    }


    deinit {
        // 通知の登録解除
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    // ダークモード変更時の処理
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        if #available(iOS 13.0, *) {
            if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
                // 背景色を更新
                view.backgroundColor = .defaultBackground

                // collectionViewがnilでないことを確認
                if let collectionView = collectionView {
                    collectionView.backgroundColor = .defaultBackground

                    // コレクションビューを再読み込み
                    collectionView.reloadData()
                }

                // searchBarの背景色を更新
                searchBar.backgroundColor = .defaultBackground
                searchBar.barTintColor = .defaultBackground

                // バナー広告の背景色を更新（FREE_VERSIONの場合）
                #if FREE_VERSION
                bannerView?.backgroundColor = .defaultBackground
                adjustGameVCHeightForBanner()
                #endif
            }
        }
    }


}


#if FREE_VERSION
extension FileSelectController: GADBannerViewDelegate {

    func adjustGameVCHeightForBanner() {
        guard let bannerView = bannerView else { return }
        let bannerHeight = bannerView.frame.height
        let safeAreaHeight = view.safeAreaLayoutGuide.layoutFrame.height
        let newGameVCHeight = safeAreaHeight - bannerHeight

        // Adjust the height of gameVC (collectionViewがnilでないことを確認)
        if let collectionView = collectionView {
            collectionView.frame.size.height = newGameVCHeight
        }

        // バナーの背景色を設定（ダークモード対応）
        bannerView.backgroundColor = .defaultBackground

        // バナーのサブビューの背景色も設定
        for subview in bannerView.subviews {
            subview.backgroundColor = .clear
        }
    }

    // GADBannerViewDelegate method
    func bannerViewDidReceiveAd(_ bannerView: GADBannerView) {
        adjustGameVCHeightForBanner()
    }

}
#endif

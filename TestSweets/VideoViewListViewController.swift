import UIKit
import Sora

private let reuseIdentifier = "Cell"

class VideoViewListViewController: UICollectionViewController,
    UICollectionViewDelegateFlowLayout,
    TestCaseControllable {
    
    weak var testCaseController: TestCaseController!

    var videoControlViewController: VideoControlViewController!

    override func viewDidLoad() {
        super.viewDidLoad()

        // Uncomment the following line to preserve selection between presentations
        // self.clearsSelectionOnViewWillAppear = false

        // Register cell classes
        self.collectionView!.register(VideoViewCollectionViewCell.self,
                                      forCellWithReuseIdentifier: reuseIdentifier)

        // Do any additional setup after loading the view.
        let control = UIBarButtonItem.init(title: "Control",
                                           style: .plain,
                                           target: self,
                                           action: #selector(showVideoControl))
        navigationItem.rightBarButtonItem = control
        navigationItem.title = "Videos"
    }

    override func viewWillAppear(_ animated: Bool) {
        reloadData()
        super.viewWillAppear(animated)
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    @objc func showVideoControl() {
        if videoControlViewController == nil {
            videoControlViewController = storyboard!
                .instantiateViewController(withIdentifier: "VideoControlViewController")
                as! VideoControlViewController
            assert(videoControlViewController != nil)
        }
        videoControlViewController.testCaseController = testCaseController
        videoControlViewController.navigationItem.title = "Video Control"
        navigationController?.pushViewController(videoControlViewController, animated: true)
    }
    
    func reloadData() {
        DispatchQueue.main.async {
            if self.collectionView?.window?.isKeyWindow ?? false {
                self.collectionView?.reloadData()
            }
        }
    }
    
    /*
    // MARK: - Navigation

    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        // Get the new view controller using [segue destinationViewController].
        // Pass the selected object to the new view controller.
    }
    */

    // MARK: UICollectionViewDataSource

    override func numberOfSections(in collectionView: UICollectionView) -> Int {
        if let chan = testCaseController.mediaChannel {
            let sections = testCaseController.testCase
                .numberOfItemsInVideoViewSection
            let streams = chan.streams.count
            return streams / sections + (streams % sections == 0 ? 0 : 1)
        } else {
            return 0
        }
    }

    override func collectionView(_ collectionView: UICollectionView,
                                 numberOfItemsInSection section: Int) -> Int {
        if let chan = testCaseController.mediaChannel {
            let items = testCaseController.testCase
                .numberOfItemsInVideoViewSection
            let streams = chan.streams.count - section * items
            if streams == 0 {
                return 0
            } else if streams % items == 0 {
                return items
            } else {
                return streams % items
            }
        } else {
            return 0
        }
    }

    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "VideoViewCell", for: indexPath)
        if let cell = cell as? VideoViewCollectionViewCell {
            cell.stream = testCaseController.mediaChannel?.streams[indexPath.row]
        }
        return cell
    }

    // MARK: UICollectionViewDelegate

    /*
    // Uncomment this method to specify if the specified item should be highlighted during tracking
    override func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        return true
    }
    */

    /*
    // Uncomment this method to specify if the specified item should be selected
    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        return true
    }
    */

    /*
    // Uncomment these methods to specify if an action menu should be displayed for the specified item, and react to actions performed on the item
    override func collectionView(_ collectionView: UICollectionView, shouldShowMenuForItemAt indexPath: IndexPath) -> Bool {
        return false
    }

    override func collectionView(_ collectionView: UICollectionView, canPerformAction action: Selector, forItemAt indexPath: IndexPath, withSender sender: Any?) -> Bool {
        return false
    }

    override func collectionView(_ collectionView: UICollectionView, performAction action: Selector, forItemAt indexPath: IndexPath, withSender sender: Any?) {
    
    }
    */

    // MARK: UICollectionViewDelegateFlowLayout
    
    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let testCase = testCaseController.testCase!
        let width = view.frame.size.width /
            CGFloat(testCase.numberOfItemsInVideoViewSection)
        let ratio = testCaseController.testCase.videoViewAspectRatio
        return ratio.size(forWidth: width)
    }
    
}

import UIKit
import Sora

private let reuseIdentifier = "Cell"

class VideoListViewController: UICollectionViewController {
    
    weak var testCase: TestCase!

    var videoControlViewController: VideoControlViewController!
    
    var mediaChannel: MediaChannel? {
        didSet {
            collectionView?.reloadData()
        }
    }
    
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
        videoControlViewController.testCase = testCase
        videoControlViewController.navigationItem.title = "Video Control"
        navigationController?.pushViewController(videoControlViewController, animated: true)
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
        print("number of sections = ", mediaChannel?.streams.count)
        return mediaChannel?.streams.count ?? 0
    }


    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return 1
    }

    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "VideoViewCell", for: indexPath)
        print("reuse: \(reuseIdentifier) cellForItemAt \(indexPath) for \(cell)")
        if let cell = cell as? VideoViewCollectionViewCell {
            cell.stream = mediaChannel?.streams[indexPath.row]
            print("stream \(cell.stream)")
            print("video view = \(cell.videoView)")
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

}

//
//  PagingMenuController.swift
//  PagingMenuController
//
//  Created by Yusuke Kita on 3/18/15.
//  Copyright (c) 2015 kitasuke. All rights reserved.
//

import UIKit

public protocol MenuControllerType {}
extension UIViewController: MenuControllerType {}

@objc public protocol PagingMenuControllerDelegate: class {
    optional func willMoveToPageMenuController(menuController: UIViewController, previousMenuController: UIViewController)
    optional func didMoveToPageMenuController(menuController: UIViewController, previousMenuController: UIViewController)
}

public class PagingMenuController: UIViewController {
    
    weak public var delegate: PagingMenuControllerDelegate?
    public private(set) var menuView: MenuView!
    public private(set) var currentPage: Int = 0
    public private(set) var currentViewController: UIViewController!
    public private(set) var visiblePagingViewControllers = [UIViewController]()
    public private(set) var pagingViewControllers = [UIViewController]() {
        willSet {
            options.menuItemCount = newValue.count
            options.menuItemViewContent = newValue.flatMap({ $0.menuItemImage }).isEmpty ? .Text : .Image
            switch options.menuItemViewContent {
            case .Text: menuItemTitles = newValue.map { $0.title ?? "Menu" }
            case .Image: menuItemImages = newValue.map { $0.menuItemImage ?? UIImage() }
            }
        }
        didSet {
            cleanup()
        }
    }
    
    private var options: PagingMenuOptions!
    private let visiblePagingViewNumber: Int = 3
    private let contentScrollView: UIScrollView = {
        let scrollView = UIScrollView(frame: .zero)
        scrollView.pagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.bounces = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        return scrollView
    }()
    private let contentView: UIView = {
        let view = UIView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    private var menuItemTitles: [String] = []
    private var menuItemImages: [UIImage] = []
    private enum PagingViewPosition {
        case Left, Center, Right, Unknown
        
        init(order: Int) {
            switch order {
            case 0: self = .Left
            case 1: self = .Center
            case 2: self = .Right
            default: self = .Unknown
            }
        }
    }
    private var previousIndex: Int {
        guard case .Infinite = options.menuDisplayMode else { return currentPage - 1 }
        
        return currentPage - 1 < 0 ? options.menuItemCount - 1 : currentPage - 1
    }
    private var nextIndex: Int {
        guard case .Infinite = options.menuDisplayMode else { return currentPage + 1 }
        
        return currentPage + 1 > options.menuItemCount - 1 ? 0 : currentPage + 1
    }
    private var currentPagingViewPosition: PagingViewPosition {
        let pageWidth = contentScrollView.frame.width
        let order = Int(ceil((contentScrollView.contentOffset.x - pageWidth / 2) / pageWidth))
        
        if case .Infinite = options.menuDisplayMode {
            return PagingViewPosition(order: order)
        }
        
        // consider left edge menu as center position
        guard currentPage == 0 && contentScrollView.contentSize.width < (pageWidth * CGFloat(visiblePagingViewNumber)) else { return PagingViewPosition(order: order) }
        return PagingViewPosition(order: order + 1)
    }
    lazy private var shouldLoadPage: (Int) -> Bool = { [unowned self] in
        switch (self.options.menuControllerSet, self.options.lazyLoadingPage) {
        case (.Single, _),
             (_, .One):
            guard $0 == self.currentPage else { return false }
        case (_, .Three):
            if case .Infinite = self.options.menuDisplayMode {
                guard $0 == self.currentPage || $0 == self.previousIndex || $0 == self.nextIndex else { return false }
            } else {
                guard $0 >= self.previousIndex && $0 <= self.nextIndex else { return false }
            }
        }
        return true
    }
    
    lazy private var isVisiblePagingViewController: (UIViewController) -> Bool = { [unowned self] in
        return self.childViewControllers.contains($0)
    }
    
    private let ExceptionName = "PMCException"

    // MARK: - Lifecycle
    
    public init<Element: MenuControllerType>(menuControllerTypes: [Element], options: PagingMenuOptions) {
        super.init(nibName: nil, bundle: nil)
        
        setup(menuControllerTypes, options: options)
    }
    
    convenience public init<Element: MenuControllerType>(menuControllerTypes: [Element]) {
        self.init(menuControllerTypes: menuControllerTypes, options: PagingMenuOptions())
    }
    
    public init<Element: MenuItemType>(menuItemTypes: [Element], options: PagingMenuOptions) {
        super.init(nibName: nil, bundle: nil)
        
        setup(menuItemTypes, options: options)
    }
    
    convenience public init<Element: MenuItemType>(menuItemTypes: [Element]) {
        self.init(menuItemTypes: menuItemTypes, options: PagingMenuOptions())
    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    public override func viewDidAppear(animated: Bool) {
        super.viewDidAppear(animated)
        
        positionMenuController()
    }
    
    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        // fix unnecessary inset for menu view when implemented by programmatically
        menuView?.contentInset.top = 0

        // position paging views correctly after view size is decided
        positionMenuController()
    }
    
    override public func viewWillTransitionToSize(size: CGSize, withTransitionCoordinator coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransitionToSize(size, withTransitionCoordinator: coordinator)
        
        if let menuView = menuView {
            menuView.updateMenuViewConstraints(size: size)
            
            coordinator.animateAlongsideTransition({ [unowned self] (_) -> Void in
                self.view.setNeedsLayout()
                self.view.layoutIfNeeded()
                
                // reset selected menu item view position
                switch self.options.menuDisplayMode {
                case .Standard, .Infinite:
                    self.moveToMenuPage(self.currentPage, animated: true)
                default: break
                }
                }, completion: nil)
        }
    }
    
    // MARK: - Public
    
    public func setup<Element: MenuControllerType>(menuControllerTypes: [Element], options: PagingMenuOptions) {
        self.options = options
        pagingViewControllers = menuControllerTypes.map { $0 as! UIViewController }
        visiblePagingViewControllers.reserveCapacity(visiblePagingViewNumber)
        
        // validate
        validateDefaultPage()
        validatePageNumbers()
        
        currentPage = options.defaultPage
        
        setupMenuView()
        setupMenuController()
        
        currentViewController = pagingViewControllers[currentPage]
        moveToMenuPage(currentPage, animated: false)
    }
    
    private func setupMenuView() {
        switch options.menuComponentType {
        case .MenuController: return
        default: break
        }
        
        constructMenuView()
        layoutMenuView()
    }
    
    private func setupMenuController() {
        switch options.menuComponentType {
        case .MenuView: return
        default: break
        }
        
        setupContentScrollView()
        layoutContentScrollView()
        setupContentView()
        layoutContentView()
        constructPagingViewControllers()
        layoutPagingViewControllers()
    }
    
    public func setup<Element: MenuItemType>(menuItemTypes: [Element], options: PagingMenuOptions) {
        self.options = options
        currentPage = options.defaultPage
        options.menuComponentType = .MenuView
        
        if let title = menuItemTypes.first where title is String {
            options.menuItemViewContent = .Text
            menuItemTitles = menuItemTypes.map { $0 as! String }
        } else if let image = menuItemTypes.first where image is UIImage {
            options.menuItemViewContent = .Image
            menuItemImages = menuItemTypes.map { $0 as! UIImage }
        }
        
        setupMenuView()
        
        menuView.moveToMenu(currentPage, animated: false)
    }
    
    public func moveToMenuPage(page: Int, animated: Bool = true) {
        switch options.menuComponentType {
        case .MenuView, .All:
            // ignore an unexpected page number
            guard page < menuView.menuItemCount else { return }
            
            let lastPage = menuView.currentPage
            guard page != lastPage else {
                // place views on appropriate position
                menuView.moveToMenu(page, animated: animated)
                positionMenuController()
                return
            }
            
            defer {
                updateCurrentPage(page)
                menuView.moveToMenu(page, animated: animated)
            }
            
            guard options.menuComponentType == .All else { return }
        case .MenuController:
            guard page < pagingViewControllers.count else { return }
            guard page != currentPage else { return }
        }
        
        // hide paging views if it's moving to far away
        hidePagingMenuControllers(page)
        
        let previousViewController = currentViewController
        
        updateCurrentPage(page)
        currentViewController = pagingViewControllers[currentPage]
        delegate?.willMoveToPageMenuController?(currentViewController, previousMenuController: previousViewController)
        
        let duration = animated ? options.animationDuration : 0
        UIView.animateWithDuration(duration, animations: {
            [unowned self] () -> Void in
            self.positionMenuController()
            }) { [weak self] (_) -> Void in
                guard let _ = self else { return }
                
                self!.relayoutPagingViewControllers()
                
                // show paging views
                self!.showPagingMenuControllers()
                
                self!.delegate?.didMoveToPageMenuController?(self!.currentViewController, previousMenuController: previousViewController)
        }
    }
    
    // MARK: - UIGestureRecognizer
    
    internal func handleTapGesture(recognizer: UITapGestureRecognizer) {
        guard let menuItemView = recognizer.view as? MenuItemView else { return }
        guard let page = menuView.menuItemViews.indexOf(menuItemView) where page != menuView.currentPage else { return }
        
        let newPage: Int
        switch self.options.menuDisplayMode {
        case .Standard(_, _, .PagingEnabled):
            newPage = page < self.currentPage ? self.currentPage - 1 : self.currentPage + 1
        case .Infinite(_, .PagingEnabled):
            if menuItemView.frame.midX > menuView.currentMenuItemView.frame.midX {
                newPage = menuView.nextPage
            } else {
                newPage = menuView.previousPage
            }
        case .Infinite: fallthrough
        default:
            newPage = page
        }
        
        moveToMenuPage(newPage)
    }
    
    internal func handleSwipeGesture(recognizer: UISwipeGestureRecognizer) {
        guard let menuView = recognizer.view as? MenuView else { return }
        
        let newPage: Int
        if recognizer.direction == .Left {
            newPage = menuView.nextPage
        } else if recognizer.direction == .Right {
            newPage = menuView.previousPage
        } else {
            return
        }
        
        moveToMenuPage(newPage)
    }
    
    // MARK: - Constructor
    
    private func constructMenuView() {
        switch options.menuComponentType {
        case .MenuController: return
        default: break
        }
        
        switch options.menuItemViewContent {
        case .Text: menuView = MenuView(menuItemTypes: menuItemTitles, options: options)
        case .Image: menuView = MenuView(menuItemTypes: menuItemImages, options: options)
        }
        
        menuView.delegate = self
        view.addSubview(menuView)
        
        addTapGestureHandlers()
        addSwipeGestureHandlersIfNeeded()
    }
    
    private func layoutMenuView() {
        // H:|[menuView]|
        // V:[menuView(height)]
        NSLayoutConstraint.activateConstraints([
            menuView.leadingAnchor.constraintEqualToAnchor(view.leadingAnchor),
            menuView.trailingAnchor.constraintEqualToAnchor(view.trailingAnchor),
            menuView.heightAnchor.constraintEqualToConstant(options.menuHeight)
            ])
        
        switch options.menuComponentType {
        case .All:
            switch options.menuPosition {
            case .Top:
                // V:|[menuView]
                menuView.topAnchor.constraintEqualToAnchor(view.topAnchor).active = true
            case .Bottom:
                // V:[menuView]|
                menuView.bottomAnchor.constraintEqualToAnchor(view.bottomAnchor).active = true
            }
        case .MenuView:
            // V:|[menuView]
            menuView.topAnchor.constraintEqualToAnchor(view.topAnchor).active = true
        default: return
        }
        
        menuView.setNeedsLayout()
        menuView.layoutIfNeeded()
    }
    
    private func setupContentScrollView() {
        contentScrollView.delegate = self
        contentScrollView.scrollEnabled = options.scrollEnabled
        view.addSubview(contentScrollView)
    }
    
    private func layoutContentScrollView() {
        // H:|[contentScrollView]|
        NSLayoutConstraint.activateConstraints([
            contentScrollView.leadingAnchor.constraintEqualToAnchor(view.leadingAnchor),
            contentScrollView.trailingAnchor.constraintEqualToAnchor(view.trailingAnchor)
            ])
        
        switch (options.menuComponentType, options.menuPosition) {
        case (.MenuController, _):
            // V:|[contentScrollView]|
            NSLayoutConstraint.activateConstraints([
                contentScrollView.topAnchor.constraintEqualToAnchor(view.leadingAnchor),
                contentScrollView.bottomAnchor.constraintEqualToAnchor(view.bottomAnchor)
                ])
        case (_, .Top):
            // V:[menuView][contentScrollView]|
            NSLayoutConstraint.activateConstraints([
                menuView.bottomAnchor.constraintEqualToAnchor(contentScrollView.topAnchor, constant: 0),
                contentScrollView.bottomAnchor.constraintEqualToAnchor(view.bottomAnchor)
                ])
        case (_, .Bottom):
            // V:|[contentScrollView][menuView]
            NSLayoutConstraint.activateConstraints([
                contentScrollView.topAnchor.constraintEqualToAnchor(view.topAnchor),
                contentScrollView.bottomAnchor.constraintEqualToAnchor(menuView.topAnchor, constant: 0)
                ])
        }
    }
    
    private func setupContentView() {
        contentScrollView.addSubview(contentView)
    }
    
    private func layoutContentView() {
        // H:|[contentView]|
        // V:|[contentView(==contentScrollView)]|
        NSLayoutConstraint.activateConstraints([
            contentView.leadingAnchor.constraintEqualToAnchor(contentScrollView.leadingAnchor),
            contentView.trailingAnchor.constraintEqualToAnchor(contentScrollView.trailingAnchor),
            contentView.topAnchor.constraintEqualToAnchor(contentScrollView.topAnchor),
            contentView.bottomAnchor.constraintEqualToAnchor(contentScrollView.bottomAnchor),
            contentView.heightAnchor.constraintEqualToAnchor(contentScrollView.heightAnchor)
            ])
    }
    
    private func constructPagingViewControllers() {
        for (index, pagingViewController) in pagingViewControllers.enumerate() {
            // construct three child view controllers at a maximum, previous(optional), current and next(optional)
            if !shouldLoadPage(index) {
                // remove unnecessary child view controllers
                if isVisiblePagingViewController(pagingViewController) {
                    pagingViewController.willMoveToParentViewController(nil)
                    pagingViewController.view!.removeFromSuperview()
                    pagingViewController.removeFromParentViewController()
                    
                    if let viewIndex = visiblePagingViewControllers.indexOf(pagingViewController) {
                        visiblePagingViewControllers.removeAtIndex(viewIndex)
                    }
                }
                continue
            }
            
            // ignore if it's already added
            if isVisiblePagingViewController(pagingViewController) {
                continue
            }
            
            guard let pagingView = pagingViewController.view else {
                fatalError("\(pagingViewController) doesn't have any view")
            }
            
            pagingView.frame = .zero
            pagingView.translatesAutoresizingMaskIntoConstraints = false

            contentView.addSubview(pagingView)
            addChildViewController(pagingViewController as UIViewController)
            pagingViewController.didMoveToParentViewController(self)
            
            visiblePagingViewControllers.append(pagingViewController)
        }
    }
    
    private func layoutPagingViewControllers() {
        // cleanup
        NSLayoutConstraint.deactivateConstraints(contentView.constraints)
        
        for (index, pagingViewController) in pagingViewControllers.enumerate() {
            if !shouldLoadPage(index) {
                continue
            }
            
            let pagingView = pagingViewController.view
            
            // only one view controller
            if options.menuItemCount == options.minumumSupportedViewCount ||
                options.lazyLoadingPage == .One ||
                options.menuControllerSet == .Single {
                // H:|[pagingView(==contentScrollView)]|
                NSLayoutConstraint.activateConstraints([
                    pagingView.leadingAnchor.constraintEqualToAnchor(contentView.leadingAnchor),
                    pagingView.trailingAnchor.constraintEqualToAnchor(contentView.trailingAnchor),
                    pagingView.widthAnchor.constraintEqualToAnchor(contentScrollView.widthAnchor)
                    ])
            } else {
                if case .Infinite = options.menuDisplayMode {
                    if index == currentPage {
                        let previousPagingView = pagingViewControllers[previousIndex].view
                        let nextPagingView = pagingViewControllers[nextIndex].view
                        
                        // H:[previousPagingView][pagingView][nextPagingView]
                        NSLayoutConstraint.activateConstraints([
                            previousPagingView.trailingAnchor.constraintEqualToAnchor(pagingView.leadingAnchor, constant: 0),
                            pagingView.trailingAnchor.constraintEqualToAnchor(nextPagingView.leadingAnchor, constant: 0)
                            ])
                    } else if index == previousIndex {
                        // "H:|[pagingView]
                        pagingView.leadingAnchor.constraintEqualToAnchor(contentView.leadingAnchor).active = true
                    } else if index == nextIndex {
                        // H:[pagingView]|
                        pagingView.trailingAnchor.constraintEqualToAnchor(contentView.trailingAnchor).active = true
                    }
                    // H:[pagingView(==contentScrollView)]
                    pagingView.widthAnchor.constraintEqualToAnchor(contentScrollView.widthAnchor).active = true
                } else {
                    if index == 0 || index == previousIndex {
                        pagingView.leadingAnchor.constraintEqualToAnchor(contentView.leadingAnchor).active = true
                    } else {
                        let previousPagingView = pagingViewControllers[index - 1].view
                        if index == pagingViewControllers.count - 1 || index == nextIndex {
                            // H:[pagingView]|
                            pagingView.trailingAnchor.constraintEqualToAnchor(contentView.trailingAnchor).active = true
                        }
                        // H:[previousPagingView][pagingView]
                        previousPagingView.trailingAnchor.constraintEqualToAnchor(pagingView.leadingAnchor, constant: 0).active = true
                    }
                    // H:[pagingView(==contentScrollView)
                    pagingView.widthAnchor.constraintEqualToAnchor(contentScrollView.widthAnchor).active = true
                }
            }
            
            // V:|[pagingView(==contentScrollView)]|
            NSLayoutConstraint.activateConstraints([
                pagingView.topAnchor.constraintEqualToAnchor(contentView.topAnchor),
                pagingView.bottomAnchor.constraintEqualToAnchor(contentView.bottomAnchor),
                pagingView.heightAnchor.constraintEqualToAnchor(contentScrollView.heightAnchor)
                ])
        }

        view.setNeedsLayout()
        view.layoutIfNeeded()
    }
    
    private func relayoutPagingViewControllers() {
        constructPagingViewControllers()
        layoutPagingViewControllers()
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }
    
    // MARK: - Cleanup
    
    private func cleanup() {
        visiblePagingViewControllers.removeAll()
        currentViewController = nil
        
        childViewControllers.forEach {
            $0.willMoveToParentViewController(nil)
            $0.view.removeFromSuperview()
            $0.removeFromParentViewController()
        }
        
        if let menuView = self.menuView {
            menuView.cleanup()
            menuView.removeFromSuperview()
            contentScrollView.removeFromSuperview()
        }
    }
    
    // MARK: - Private
    
    private func positionMenuController() {
        if let currentViewController = currentViewController,
            let currentView = currentViewController.view {
            contentScrollView.contentOffset.x = currentView.frame.minX
        }
    }
    
    private func updateCurrentPage(page: Int) {
        let currentPage = page % options.menuItemCount
        self.currentPage = currentPage
    }
    
    private func hidePagingMenuControllers(page: Int) {
        switch (options.lazyLoadingPage, options.menuDisplayMode, page) {
        case (.Three, _, previousIndex),
             (.Three, _, nextIndex): break
        default: visiblePagingViewControllers.forEach { $0.view.alpha = 0 }
        }
    }
    
    private func showPagingMenuControllers() {
        visiblePagingViewControllers.forEach { $0.view.alpha = 1 }
    }
    
    // MARK: - Gesture handler
    
    private func addTapGestureHandlers() {
        menuView.menuItemViews.forEach {
            let gestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(PagingMenuController.handleTapGesture(_:)))
            gestureRecognizer.numberOfTapsRequired = 1
            $0.addGestureRecognizer(gestureRecognizer)
        }
    }
    
    private func addSwipeGestureHandlersIfNeeded() {
        switch options.menuDisplayMode {
        case .Standard(_, _, .PagingEnabled): break
        case .Infinite(_, .PagingEnabled): break
        default: return
        }
        
        let leftSwipeGesture = UISwipeGestureRecognizer(target: self, action: #selector(PagingMenuController.handleSwipeGesture(_:)))
        leftSwipeGesture.direction = .Left
        menuView.panGestureRecognizer.requireGestureRecognizerToFail(leftSwipeGesture)
        menuView.addGestureRecognizer(leftSwipeGesture)
        let rightSwipeGesture = UISwipeGestureRecognizer(target: self, action: #selector(PagingMenuController.handleSwipeGesture(_:)))
        rightSwipeGesture.direction = .Right
        menuView.panGestureRecognizer.requireGestureRecognizerToFail(rightSwipeGesture)
        menuView.addGestureRecognizer(rightSwipeGesture)
    }
    
    // MARK: - Validator
    
    private func validateDefaultPage() {
        guard options.defaultPage >= options.menuItemCount || options.defaultPage < 0 else { return }
        
        NSException(name: ExceptionName, reason: "default page is invalid", userInfo: nil).raise()
    }
    
    private func validatePageNumbers() {
        guard case .Infinite = options.menuDisplayMode else { return }
        guard options.menuItemCount < visiblePagingViewNumber else { return }
        
        NSException(name: ExceptionName, reason: "the number of view controllers should be more than three with Infinite display mode", userInfo: nil).raise()
    }
}

extension PagingMenuController: UIScrollViewDelegate {
    private var nextPageFromCurrentPosition: Int {
        // set new page number according to current moving direction
        let nextPage: Int
        switch currentPagingViewPosition {
        case .Left:
            nextPage = options.menuComponentType == .MenuController ? previousIndex : menuView.previousPage
        case .Right:
            nextPage = options.menuComponentType == .MenuController ? nextIndex : menuView.nextPage
        default: nextPage = currentPage
        }
        return nextPage
    }
    
    private var nextPageFromCurrentPoint: Int {
        let point = CGPointMake(menuView.contentOffset.x + menuView.frame.width / 2, 0)
        for (index, menuItemView) in menuView.menuItemViews.enumerate() {
            guard CGRectContainsPoint(menuItemView.frame, point) else { continue }
            return index
        }
        return currentPage
    }
    
    // MARK: - UIScrollViewDelegate
    
    public func scrollViewDidEndDecelerating(scrollView: UIScrollView) {
        let nextPage: Int
        switch scrollView {
        case let scrollView where scrollView.isEqual(contentScrollView):
            nextPage = nextPageFromCurrentPosition
        case let scrollView where scrollView.isEqual(menuView):
            nextPage = nextPageFromCurrentPoint
        default: return
        }
        
        moveToMenuPage(nextPage)
    }
    
    public func scrollViewDidEndDragging(scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        switch (scrollView, decelerate) {
        case (let scrollView, false) where scrollView.isEqual(menuView): break
        default: return
        }
        
        let nextPage = nextPageFromCurrentPoint
        moveToMenuPage(nextPage)
    }
}
//
//  ViewController.swift
//  Managed View
//

import Foundation
import UIKit
@preconcurrency import WebKit

class ViewController: UIViewController, UITextFieldDelegate, WKUIDelegate, WKNavigationDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate {
  
  @IBOutlet weak var browserURL: UITextField!  //BROWSER MODE ONLY: URL address bar
  var webView: WKWebView?
  
  // Keep track of all webViews created by createWebViewWith
  private var additionalWebViews: [WKWebView] = []
  
  private var kioskConfiguration: KioskConfiguration?
  private var configurationGeneration = 0
  private var configurationMessage: UILabel?
  private var configurationObserver: NSObjectProtocol?
  private var activeHomeURL: URL?
  private var resumeAfterInterruption = false
  
  
  
  // Loading indicator components
  private var loadingIndicator: UIActivityIndicatorView?
  private var loadingBackgroundView: UIView?
  private var loadingLabel: UILabel?
  
  // Add flag to prevent double taps on browser buttons
  private var isBrowserBarAnimating = false
  
  // Navigation bar button outlets for enabling/disabling during loading
  @IBOutlet weak var backButton: UIBarButtonItem?
  @IBOutlet weak var forwardButton: UIBarButtonItem?
  @IBOutlet weak var refreshButton: UIBarButtonItem?
  @IBOutlet weak var homeButton: UIBarButtonItem?
  
  // local app configuration
  struct Config {
    var maintenanceMode: String           // display curtain image
    var newURL: URL?                      // new URL request
    var previousURL: URL?                 // previously loaded URL
    var browserMode: String               // display user interactive browser controls
    var browserModeNoEdit: String         // disable address bar edit
    var homeURL: URL?                     // BROWSER MODE ONLY: URL for home button
    var privateBrowsing: String           // private browsing mode
    var resetTimer: Int                   // timer in seconds to reset session
    var launchDelay: Int                  // initial page load delayed by seconds
    var detectScroll: String              // reset timer if scrolling
    var redirect: String                  // redirect new tabs / pop-ups to webview
    var autoOpenPopup: String             // allow javascipt to auto open popup
    var brightness: Int                   // device brightness control (-1=disabled, 0-100=brightness %)
    var resetTimerOnHome: String          // enable reset timer when at home URL
    var resetTimerWarning: Int            // seconds before reset to show warning (0=disabled)
    var userAgent: String                 // custom user agent string (empty = default WebKit UA)
    var displayURL: URL? {
      if maintenanceMode == "ON" {  // display curtain image
        return Bundle.main.url(forResource: "curtain", withExtension: "png", subdirectory: "img")
      }
      else { // or new URL request
        return newURL
      }
    }
  }
  
  // set local configuration defaults
  var config = Config(maintenanceMode: "OFF",
                      newURL: nil,
                      previousURL: nil,
                      browserMode: "OFF",
                      browserModeNoEdit: "OFF",
                      homeURL: nil,
                      privateBrowsing: "OFF",
                      resetTimer: 0,
                      launchDelay: 0,
                      detectScroll: "ON",
                      redirect: "OFF",
                      autoOpenPopup: "OFF",
                      brightness: -1,
                      resetTimerOnHome: "OFF",
                      resetTimerWarning: 0,
                      userAgent: ""
  )
  
  var timer: Timer?
  
  // Warning timer for reset countdown
  private var warningTimer: Timer?
  private var warningBannerView: UIView?
  private var warningLabel: UILabel?
  private var countdownLabel: UILabel?
  private var countdownTimer: Timer?
  private var countdownSeconds: Int = 0
  
  
  
  // WKWebView setup via code - required for < iOS 11
  override func loadView() {
    super.loadView()
    // Initial webView creation will happen in viewDidLoad
  }
  
  //  Hide Top Status Bar
  override var prefersStatusBarHidden: Bool {
    return true
  }
  
  @objc func appCameToForeGround(notification: Notification) {
    readManagedAppConfig()
  }
  
  override func viewDidLoad() {
    super.viewDidLoad()
    
    // Configure navigation bar appearance to respect system appearance mode
    configureNavigationBarAppearance()
    
    // Observe removal as well as delivery. Missing configuration must stop browsing.
    configurationObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.readManagedAppConfig() }
    readManagedAppConfig()

    // version 2.8.10 - add device lock detection
    addDeviceLockDetection()
    
    NotificationCenter.default.addObserver(self,
                                           selector: #selector(appCameToForeGround(notification:)),
                                           name: UIApplication.willEnterForegroundNotification,
                                           object: nil)
    

    
  }
  
  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    
    // Reconfigure appearance when appearance mode changes
    if #available(iOS 13.0, *) {
      if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
        configureNavigationBarAppearance()
      }
    }
  }
  
  private func configureNavigationBarAppearance() {
    guard let navigationController = navigationController else { return }
    
    if #available(iOS 13.0, *) {
      // Use the new appearance API for iOS 13+
      let appearance = UINavigationBarAppearance()
      appearance.configureWithDefaultBackground() // This will respect system appearance
      
      navigationController.navigationBar.standardAppearance = appearance
      navigationController.navigationBar.scrollEdgeAppearance = appearance
      navigationController.navigationBar.compactAppearance = appearance
      
      // Remove any fixed tint colors to allow system colors
      navigationController.navigationBar.barTintColor = nil
      navigationController.navigationBar.backgroundColor = nil
    } else {
      // For iOS 12 and earlier, use system default
      navigationController.navigationBar.barTintColor = nil
      navigationController.navigationBar.backgroundColor = nil
      navigationController.navigationBar.barStyle = .default
    }
  }
  
  private var previousManagedValues: NSDictionary?

  func readManagedAppConfig() {
    precondition(Thread.isMainThread)
    let values = UserDefaults.standard.dictionary(forKey: "com.apple.configuration.managed") ?? [:]
    let snapshot = values as NSDictionary
    if let previous = previousManagedValues, previous.isEqual(snapshot) { return }
    previousManagedValues = snapshot.copy() as? NSDictionary
    configurationGeneration += 1
    let generation = configurationGeneration
    kioskConfiguration = nil
    timer?.invalidate()
    cancelWarningTimer()
    webView?.stopLoading()
    webView?.removeFromSuperview()
    webView = nil
    for browser in additionalWebViews {
      browser.stopLoading()
      browser.removeFromSuperview()
    }
    additionalWebViews.removeAll()
    hideLoadingIndicator()
    navigationController?.isNavigationBarHidden = true

    guard !values.isEmpty else {
      activeHomeURL = nil
      WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                            modifiedSince: .distantPast) {}
      showConfigurationMessage("Waiting for configuration from Intune.\nContact IT if this message remains.")
      return
    }
    do {
      let validated = try KioskConfiguration.parse(values)
      showConfigurationMessage("Applying kiosk configuration…")
      // Clear old sessions whenever the configured home changes, including club reassignment.
      let apply = { [weak self] in
        DispatchQueue.main.async {
          guard let self = self, self.configurationGeneration == generation else { return }
          self.applyConfiguration(validated, generation: generation)
        }
      }
      if activeHomeURL != validated.homeURL {
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                              modifiedSince: .distantPast, completionHandler: apply)
      } else { apply() }
    } catch {
      activeHomeURL = nil
      showConfigurationMessage((error as? LocalizedError)?.errorDescription ?? "Invalid kiosk configuration. Contact IT.")
    }
  }

  private func applyConfiguration(_ validated: KioskConfiguration, generation: Int) {
    kioskConfiguration = validated
    activeHomeURL = validated.homeURL
    config.newURL = validated.homeURL
    config.homeURL = validated.homeURL
    config.previousURL = nil
    config.maintenanceMode = validated.switches["MAINTENANCE_MODE"] ?? "OFF"
    config.browserMode = validated.switches["BROWSER_MODE"] ?? "OFF"
    config.browserModeNoEdit = validated.switches["BROWSER_BAR_NO_EDIT"] ?? "OFF"
    config.privateBrowsing = validated.switches["PRIVATE_BROWSING"] ?? "OFF"
    config.detectScroll = validated.switches["DETECT_SCROLL"] ?? "OFF"
    config.redirect = validated.switches["REDIRECT_SUPPORT"] ?? "OFF"
    config.autoOpenPopup = validated.switches["AUTO_OPEN_POPUP"] ?? "OFF"
    config.resetTimerOnHome = validated.switches["RESET_TIMER_ON_HOME"] ?? "OFF"
    config.resetTimer = validated.integers["RESET_TIMER"] ?? 0
    config.resetTimerWarning = validated.integers["RESET_TIMER_WARNING"] ?? 0
    config.launchDelay = validated.integers["LAUNCH_DELAY"] ?? 0
    config.brightness = validated.integers["BRIGHTNESS"] ?? -1
    config.userAgent = validated.userAgent
    // Intune owns device lockdown. Website URLs cannot release Single App Mode.
    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(config.launchDelay)) { [weak self] in
      guard let self = self, self.configurationGeneration == generation else { return }
      self.configurationMessage?.isHidden = true
      self.createWebView(isPrivate: self.config.privateBrowsing == "ON")
      self.checkBrowserMode()
      self.setBrightness()
    }
  }

  private func showConfigurationMessage(_ text: String) {
    if configurationMessage == nil {
      let label = UILabel()
      label.numberOfLines = 0
      label.textAlignment = .center
      label.textColor = .label
      label.backgroundColor = .systemBackground
      label.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(label)
      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
        label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
      ])
      configurationMessage = label
    }
    configurationMessage?.text = text
    configurationMessage?.isHidden = false
    if let label = configurationMessage { view.bringSubviewToFront(label) }
  }

  // MARK: - Brightness Control
  private func setBrightness() {
    // Only set brightness if the value is >= 0 (-1 means disabled/default)
    guard config.brightness >= 0 else {
      return
    }
    
    // Ensure the value is within valid range (0-100)
    let clampedValue = max(0, min(100, config.brightness))
    
    // Convert from 0-100 range to 0.0-1.0 range for UIScreen.brightness
    let screenBrightness = Float(clampedValue) / 100.0
    
    DispatchQueue.main.async {
      UIScreen.main.brightness = CGFloat(screenBrightness)
    }
  }
  
  // MARK: - Loading Indicator
  private func createLoadingIndicator() {
    // Only create if it doesn't already exist
    guard loadingIndicator == nil else { return }
    
    // Create background view
    loadingBackgroundView = UIView()
    loadingBackgroundView?.backgroundColor = UIColor.black.withAlphaComponent(0.5)
    loadingBackgroundView?.translatesAutoresizingMaskIntoConstraints = false
    
    // Create activity indicator
    if #available(iOS 13.0, *) {
      loadingIndicator = UIActivityIndicatorView(style: .large)
    } else {
      loadingIndicator = UIActivityIndicatorView(style: .whiteLarge)
    }
    loadingIndicator?.color = .white
    loadingIndicator?.translatesAutoresizingMaskIntoConstraints = false
    
    // Create loading label
    loadingLabel = UILabel()
    loadingLabel?.text = "Loading..."
    loadingLabel?.textColor = .white
    loadingLabel?.font = UIFont.systemFont(ofSize: 16)
    loadingLabel?.translatesAutoresizingMaskIntoConstraints = false
    
    guard let backgroundView = loadingBackgroundView,
          let indicator = loadingIndicator,
          let label = loadingLabel else { return }
    
    // Add to view hierarchy
    view.addSubview(backgroundView)
    backgroundView.addSubview(indicator)
    backgroundView.addSubview(label)
    
    // Set up constraints to cover entire screen including navigation bar
    NSLayoutConstraint.activate([
      // Background view fills entire screen, extending beyond safe area
      backgroundView.topAnchor.constraint(equalTo: view.topAnchor),
      backgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      
      // Center activity indicator
      indicator.centerXAnchor.constraint(equalTo: backgroundView.centerXAnchor),
      indicator.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
      
      // Position label below indicator
      label.centerXAnchor.constraint(equalTo: backgroundView.centerXAnchor),
      label.topAnchor.constraint(equalTo: indicator.bottomAnchor, constant: 16)
    ])
    
    // Initially hidden
    backgroundView.isHidden = true
  }
  
  // MARK: - Navigation Button Control
  private func setNavigationButtonsEnabled(_ enabled: Bool) {
    DispatchQueue.main.async {
      // Only control buttons if they exist and browser mode is ON
      guard self.config.browserMode == "ON" else { return }
      
      // Get navigation bar buttons programmatically since outlets may not be connected
      if let leftBarButtonItems = self.navigationItem.leftBarButtonItems {
        for button in leftBarButtonItems {
          button.isEnabled = enabled
        }
      }
      
      if let rightBarButtonItems = self.navigationItem.rightBarButtonItems {
        for button in rightBarButtonItems {
          button.isEnabled = enabled
        }
      }
      
      // Also try the outlet approach if they're connected
      self.backButton?.isEnabled = enabled
      self.forwardButton?.isEnabled = enabled
      self.refreshButton?.isEnabled = enabled
      self.homeButton?.isEnabled = enabled
      
    }
  }
  
  private func showLoadingIndicator() {
    DispatchQueue.main.async {
      // Create if needed
      self.createLoadingIndicator()
      
      // Disable navigation buttons during loading
      self.setNavigationButtonsEnabled(false)
      
      // Show and start animating
      self.loadingBackgroundView?.isHidden = false
      self.loadingIndicator?.startAnimating()
      
      // Add to navigation controller's view if available to cover nav bar, otherwise use our view
      let targetView = self.navigationController?.view ?? self.view!
      
      // Remove from current parent if it exists
      self.loadingBackgroundView?.removeFromSuperview()
      
      // Add to the target view
      if let backgroundView = self.loadingBackgroundView {
        targetView.addSubview(backgroundView)
        
        // Update constraints for the new parent view
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
          backgroundView.topAnchor.constraint(equalTo: targetView.topAnchor),
          backgroundView.leadingAnchor.constraint(equalTo: targetView.leadingAnchor),
          backgroundView.trailingAnchor.constraint(equalTo: targetView.trailingAnchor),
          backgroundView.bottomAnchor.constraint(equalTo: targetView.bottomAnchor)
        ])
        
        // Bring to front to ensure it's visible above everything
        targetView.bringSubviewToFront(backgroundView)
      }
    }
  }
  
  private func hideLoadingIndicator() {
    DispatchQueue.main.async {
      self.loadingBackgroundView?.isHidden = true
      self.loadingIndicator?.stopAnimating()
      
      // Re-enable navigation buttons when loading is complete
      self.setNavigationButtonsEnabled(true)
    }
  }
  
  // MARK: - Reset Warning Banner
  private var continueButton: UIButton?
  private var warningOverlayView: UIView?
  
  private func createWarningBanner() {
    // Only create if it doesn't already exist
    guard warningBannerView == nil else { return }
    
    let targetView = navigationController?.view ?? view!
    
    // Create semi-transparent overlay
    warningOverlayView = UIView()
    warningOverlayView?.backgroundColor = UIColor.black.withAlphaComponent(0.4)
    warningOverlayView?.translatesAutoresizingMaskIntoConstraints = false
    
    // Create banner container (white card)
    warningBannerView = UIView()
    warningBannerView?.backgroundColor = UIColor.systemBackground
    warningBannerView?.translatesAutoresizingMaskIntoConstraints = false
    warningBannerView?.layer.cornerRadius = 16
    warningBannerView?.layer.shadowColor = UIColor.black.cgColor
    warningBannerView?.layer.shadowOffset = CGSize(width: 0, height: 4)
    warningBannerView?.layer.shadowOpacity = 0.3
    warningBannerView?.layer.shadowRadius = 8
    
    // Create icon image view (using SF Symbol)
    let iconImageView = UIImageView()
    if #available(iOS 13.0, *) {
      let config = UIImage.SymbolConfiguration(pointSize: 40, weight: .regular)
      iconImageView.image = UIImage(systemName: "timer", withConfiguration: config)
      iconImageView.tintColor = .secondaryLabel
    }
    iconImageView.contentMode = .scaleAspectFit
    iconImageView.translatesAutoresizingMaskIntoConstraints = false
    
    // Create icon background
    let iconBackground = UIView()
    iconBackground.backgroundColor = UIColor.secondarySystemBackground
    iconBackground.layer.cornerRadius = 12
    iconBackground.translatesAutoresizingMaskIntoConstraints = false
    
    // Create title label
    let titleLabel = UILabel()
    titleLabel.text = "Your session will be reset soon"
    titleLabel.textColor = .label
    titleLabel.font = UIFont.boldSystemFont(ofSize: 20)
    titleLabel.textAlignment = .center
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    
    // Create description label
    warningLabel = UILabel()
    let timerDescription = formatTimerDuration(seconds: config.resetTimer)
    warningLabel?.text = "This happens when device isn't used for \(timerDescription)."
    warningLabel?.textColor = .secondaryLabel
    warningLabel?.font = UIFont.systemFont(ofSize: 15)
    warningLabel?.textAlignment = .center
    warningLabel?.numberOfLines = 0
    warningLabel?.translatesAutoresizingMaskIntoConstraints = false
    
    // Create countdown container
    let countdownContainer = UIView()
    countdownContainer.backgroundColor = UIColor.secondarySystemBackground
    countdownContainer.layer.cornerRadius = 8
    countdownContainer.translatesAutoresizingMaskIntoConstraints = false
    
    // Create countdown label
    countdownLabel = UILabel()
    countdownLabel?.text = "Time Remaining: 10 seconds"
    countdownLabel?.textColor = .label
    countdownLabel?.font = UIFont.systemFont(ofSize: 15)
    countdownLabel?.textAlignment = .center
    countdownLabel?.translatesAutoresizingMaskIntoConstraints = false
    
    // Create continue button
    continueButton = UIButton(type: .system)
    continueButton?.setTitle("Continue using", for: .normal)
    continueButton?.setTitleColor(.white, for: .normal)
    continueButton?.titleLabel?.font = UIFont.boldSystemFont(ofSize: 17)
    continueButton?.backgroundColor = UIColor.systemBlue
    continueButton?.layer.cornerRadius = 25
    continueButton?.translatesAutoresizingMaskIntoConstraints = false
    continueButton?.addTarget(self, action: #selector(continueButtonTapped), for: .touchUpInside)
    
    guard let overlay = warningOverlayView,
          let bannerView = warningBannerView,
          let warning = warningLabel,
          let countdown = countdownLabel,
          let button = continueButton else { return }
    
    // Add to view hierarchy
    targetView.addSubview(overlay)
    targetView.addSubview(bannerView)
    iconBackground.addSubview(iconImageView)
    bannerView.addSubview(iconBackground)
    bannerView.addSubview(titleLabel)
    bannerView.addSubview(warning)
    bannerView.addSubview(countdownContainer)
    countdownContainer.addSubview(countdown)
    bannerView.addSubview(button)
    
    // Set up constraints
    NSLayoutConstraint.activate([
      // Overlay covers entire screen
      overlay.topAnchor.constraint(equalTo: targetView.topAnchor),
      overlay.leadingAnchor.constraint(equalTo: targetView.leadingAnchor),
      overlay.trailingAnchor.constraint(equalTo: targetView.trailingAnchor),
      overlay.bottomAnchor.constraint(equalTo: targetView.bottomAnchor),
      
      // Banner centered in screen
      bannerView.centerXAnchor.constraint(equalTo: targetView.centerXAnchor),
      bannerView.centerYAnchor.constraint(equalTo: targetView.centerYAnchor),
      bannerView.leadingAnchor.constraint(greaterThanOrEqualTo: targetView.leadingAnchor, constant: 24),
      bannerView.trailingAnchor.constraint(lessThanOrEqualTo: targetView.trailingAnchor, constant: -24),
      bannerView.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
      
      // Icon background at top
      iconBackground.topAnchor.constraint(equalTo: bannerView.topAnchor, constant: 24),
      iconBackground.centerXAnchor.constraint(equalTo: bannerView.centerXAnchor),
      iconBackground.widthAnchor.constraint(equalToConstant: 64),
      iconBackground.heightAnchor.constraint(equalToConstant: 64),
      
      // Icon centered in background
      iconImageView.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
      iconImageView.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
      iconImageView.widthAnchor.constraint(equalToConstant: 40),
      iconImageView.heightAnchor.constraint(equalToConstant: 40),
      
      // Title below icon
      titleLabel.topAnchor.constraint(equalTo: iconBackground.bottomAnchor, constant: 16),
      titleLabel.leadingAnchor.constraint(equalTo: bannerView.leadingAnchor, constant: 24),
      titleLabel.trailingAnchor.constraint(equalTo: bannerView.trailingAnchor, constant: -24),
      
      // Description below title
      warning.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
      warning.leadingAnchor.constraint(equalTo: bannerView.leadingAnchor, constant: 24),
      warning.trailingAnchor.constraint(equalTo: bannerView.trailingAnchor, constant: -24),
      
      // Countdown container below description
      countdownContainer.topAnchor.constraint(equalTo: warning.bottomAnchor, constant: 20),
      countdownContainer.centerXAnchor.constraint(equalTo: bannerView.centerXAnchor),
      countdownContainer.heightAnchor.constraint(equalToConstant: 36),
      
      // Countdown label inside container
      countdown.topAnchor.constraint(equalTo: countdownContainer.topAnchor, constant: 8),
      countdown.bottomAnchor.constraint(equalTo: countdownContainer.bottomAnchor, constant: -8),
      countdown.leadingAnchor.constraint(equalTo: countdownContainer.leadingAnchor, constant: 16),
      countdown.trailingAnchor.constraint(equalTo: countdownContainer.trailingAnchor, constant: -16),
      
      // Continue button at bottom
      button.topAnchor.constraint(equalTo: countdownContainer.bottomAnchor, constant: 24),
      button.leadingAnchor.constraint(equalTo: bannerView.leadingAnchor, constant: 24),
      button.trailingAnchor.constraint(equalTo: bannerView.trailingAnchor, constant: -24),
      button.heightAnchor.constraint(equalToConstant: 50),
      button.bottomAnchor.constraint(equalTo: bannerView.bottomAnchor, constant: -24)
    ])
    
    // Initially hidden
    overlay.isHidden = true
    overlay.alpha = 0
    bannerView.isHidden = true
    bannerView.alpha = 0
  }
  
  @objc private func continueButtonTapped() {
    
    // Cancel warning and reset timer
    timer?.invalidate()
    cancelWarningTimer()
    
    // Restart the timer if needed
    if config.resetTimer != 0 {
      let shouldStartTimer: Bool
      if config.resetTimerOnHome == "ON" {
        shouldStartTimer = true
      } else {
        shouldStartTimer = (webView?.url != config.homeURL)
      }
      
      if shouldStartTimer {
        timer = Timer.scheduledTimer(timeInterval: TimeInterval(config.resetTimer),
                                     target: self,
                                     selector: #selector(fireTimer),
                                     userInfo: nil,
                                     repeats: false)
        startWarningTimer()
      }
    }
  }
  
  private func showWarningBanner(secondsRemaining: Int) {
    DispatchQueue.main.async {
      // Create banner if needed
      self.createWarningBanner()
      
      // Set initial countdown
      self.countdownSeconds = secondsRemaining
      self.updateCountdownLabel()
      
      // Show overlay and banner with animation
      self.warningOverlayView?.isHidden = false
      self.warningBannerView?.isHidden = false
      UIView.animate(withDuration: 0.3) {
        self.warningOverlayView?.alpha = 1.0
        self.warningBannerView?.alpha = 1.0
      }
      
      // Start countdown timer
      self.countdownTimer?.invalidate()
      self.countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
        guard let self = self else { return }
        self.countdownSeconds -= 1
        self.updateCountdownLabel()
        
        if self.countdownSeconds <= 0 {
          self.countdownTimer?.invalidate()
          self.countdownTimer = nil
        }
      }
      
    }
  }
  
  private func hideWarningBanner() {
    // Stop countdown timer immediately (on current thread if main, otherwise dispatch)
    if Thread.isMainThread {
      self.countdownTimer?.invalidate()
      self.countdownTimer = nil
      
      // Hide overlay and banner with animation
      UIView.animate(withDuration: 0.3, animations: {
        self.warningOverlayView?.alpha = 0
        self.warningBannerView?.alpha = 0
      }) { _ in
        self.warningOverlayView?.isHidden = true
        self.warningBannerView?.isHidden = true
      }
      
    } else {
      DispatchQueue.main.async {
        self.countdownTimer?.invalidate()
        self.countdownTimer = nil
        
        // Hide overlay and banner with animation
        UIView.animate(withDuration: 0.3, animations: {
          self.warningOverlayView?.alpha = 0
          self.warningBannerView?.alpha = 0
        }) { _ in
          self.warningOverlayView?.isHidden = true
          self.warningBannerView?.isHidden = true
        }
        
      }
    }
  }
  
  private func updateCountdownLabel() {
    DispatchQueue.main.async {
      self.countdownLabel?.text = "Time Remaining: \(self.countdownSeconds) seconds"
    }
  }
  
  private func startWarningTimer() {
    // Only start warning timer if both reset timer and warning are configured
    guard config.resetTimer > 0, config.resetTimerWarning > 0 else { return }
    
    // Warning should be less than the reset timer
    guard config.resetTimerWarning < config.resetTimer else {
      return
    }
    
    // Calculate when to show the warning
    let warningDelay = config.resetTimer - config.resetTimerWarning
    
    warningTimer?.invalidate()
    warningTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(warningDelay), repeats: false) { [weak self] _ in
      guard let self = self else { return }
      self.showWarningBanner(secondsRemaining: self.config.resetTimerWarning)
    }
    
  }
  
  private func cancelWarningTimer() {
    // Stop the warning timer that triggers the banner
    warningTimer?.invalidate()
    warningTimer = nil
    
    // Also stop countdown timer directly (in case banner is showing)
    countdownTimer?.invalidate()
    countdownTimer = nil
    
    // Hide the banner if visible
    hideWarningBanner()
  }
  
  private func formatTimerDuration(seconds: Int) -> String {
    if seconds >= 60 {
      let minutes = seconds / 60
      if minutes == 1 {
        return "1 minute"
      } else {
        return "\(minutes) minutes"
      }
    } else {
      if seconds == 1 {
        return "1 second"
      } else {
        return "\(seconds) seconds"
      }
    }
  }

  private func createWebView(isPrivate: Bool) {
    // Clean up any existing webView
    webView?.removeFromSuperview()
    
    let webConfiguration = WKWebViewConfiguration()
    if isPrivate {
      webConfiguration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
    }
    
    // Enable inline media playback and allow audio/video without user gesture
    webConfiguration.allowsInlineMediaPlayback = true
    webConfiguration.mediaTypesRequiringUserActionForPlayback = []
    
    // version 2.8.2 - auto open popup
    if config.autoOpenPopup == "ON" {
      webConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = true
    }
    
    webView = WKWebView(frame: .zero, configuration: webConfiguration)
    guard let webView = webView else {
        return
    }
    
    webView.uiDelegate = self
    webView.navigationDelegate = self
    browserURL.delegate = self
    if !config.userAgent.isEmpty {
      webView.customUserAgent = config.userAgent
    }
    if #available(iOS 11.0, *) {
      webView.scrollView.contentInsetAdjustmentBehavior = .never
    }
    
    view.addSubview(webView)
    webView.translatesAutoresizingMaskIntoConstraints = false
    
    NSLayoutConstraint.activate([
      webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    ])
    
    webView.scrollView.delegate = self
    
    addUserActivityDetection()
    
    if isPrivate {
    } else {
    }
    
    loadWebViewIfNeeded()
  }

  // load new URL request & check scheme (v2.3.1)
  // version 2.8.12 - updated check scheme method
  func loadWebViewIfNeeded() {
    guard let webView = webView, kioskConfiguration != nil else { return }
    guard let url = config.displayURL, permitsNavigation(to: url) else { return }
    showLoadingIndicator()
    webView.load(URLRequest(url: url))
    config.previousURL = url
  }

  private func isCurrentBrowser(_ browser: WKWebView) -> Bool {
    browser === webView || additionalWebViews.contains { $0 === browser }
  }

  private func permitsNavigation(to url: URL) -> Bool {
    guard let policy = kioskConfiguration else { return false }
    if config.maintenanceMode == "ON", url.isFileURL,
       let image = Bundle.main.url(forResource: "curtain", withExtension: "png", subdirectory: "img") {
      return url.standardizedFileURL == image.standardizedFileURL
    }
    return policy.permits(url)
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard isCurrentBrowser(webView), kioskConfiguration != nil, let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    // Blank child frames are used by some websites. Top-level navigation still requires HTTPS.
    let blankChild = url.absoluteString == "about:blank" && navigationAction.targetFrame?.isMainFrame == false
    decisionHandler(permitsNavigation(to: url) || blankChild ? .allow : .cancel)
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
               decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    guard isCurrentBrowser(webView), let url = navigationResponse.response.url, kioskConfiguration != nil else {
      decisionHandler(.cancel)
      return
    }
    let blankChild = url.absoluteString == "about:blank" && !navigationResponse.isForMainFrame
    decisionHandler(permitsNavigation(to: url) || blankChild ? .allow : .cancel)
  }

  func checkBrowserMode() {
    if config.browserMode == "ON" {
      navigationController?.isNavigationBarHidden = false
      navigationController?.hidesBarsOnSwipe = true
      if config.browserModeNoEdit == "ON" {
        browserURL.isEnabled = false
      }
      
    } else {
      navigationController?.isNavigationBarHidden = true
      navigationController?.hidesBarsOnSwipe = false
    }
    
    navigationController?.isToolbarHidden = true
    self.toolbarItems = nil
    view.layoutIfNeeded()
  }

  // BROWSER MODE ONLY: 4 connectors to UI
  @IBAction func goBack(_ sender: Any) {
    provideBrowserButtonFeedback(for: sender)
    webView?.goBack()
  }
  @IBAction func goForward(_ sender: Any) {
    provideBrowserButtonFeedback(for: sender)
    webView?.goForward()
  }
  @IBAction func refreshPage(_ sender: Any) {
    provideBrowserButtonFeedback(for: sender)
    webView?.reload()
  }
  @IBAction func goHome(_ sender: Any) {
    provideBrowserButtonFeedback(for: sender)
    self.resetSession()
  }
  
  // MARK: - Browser Button Feedback
  private func provideBrowserButtonFeedback(for sender: Any) {
    // Prevent double taps during animation
    guard !isBrowserBarAnimating else {
      return
    }
    
    // Only proceed if browser mode is ON and navigation bar is visible
    guard config.browserMode == "ON",
          let navigationController = navigationController,
          !navigationController.isNavigationBarHidden else {
      return
    }
    
    isBrowserBarAnimating = true
    
    // Haptic feedback
    let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
    impactFeedback.impactOccurred()
    
    // Hide navigation bar with animation (0.4 seconds)
    UIView.animate(withDuration: 0.4, animations: {
      navigationController.setNavigationBarHidden(true, animated: false)
      self.view.layoutIfNeeded()
    }) { _ in
      // Show navigation bar again after a brief delay (0.2s delay + 0.4s animation = 1.0s total)
      UIView.animate(withDuration: 0.4, delay: 0.2, options: [], animations: {
        navigationController.setNavigationBarHidden(false, animated: false)
        self.view.layoutIfNeeded()
      }) { _ in
        self.isBrowserBarAnimating = false
      }
    }
  }
  
  // BROWSER MODE ONLY: enable user input via URL address bar
  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    textField.resignFirstResponder() // hide the keyboard
    
    guard webView != nil else { return true }
    
    guard let userURL = URL(string: browserURL.text ?? ""),
          kioskConfiguration?.permits(userURL) == true else { return true }
    config.newURL = userURL
    loadWebViewIfNeeded()

    return true
  }
  
  @objc func fireTimer() {
    hideWarningBanner()
    resetSession()
  }
  
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard isCurrentBrowser(webView), kioskConfiguration != nil else { return }
    configurationMessage?.isHidden = true
    // Hide loading indicator when page finishes loading
    hideLoadingIndicator()
    
    UIApplication.shared.isNetworkActivityIndicatorVisible = true
    
    if let url = webView.url {
      self.browserURL.text = String(describing: url)
    }
    
    // version 2.2 - timer to refresh session
    if config.resetTimer != 0 {
      timer?.invalidate()
      cancelWarningTimer()
      
      // Check if we should start timer based on current URL and resetTimerOnHome setting
      let shouldStartTimer: Bool
      if config.resetTimerOnHome == "ON" {
        // When resetTimerOnHome is ON, always start the timer regardless of URL
        shouldStartTimer = true
      } else {
        // Default behavior: only start timer when NOT at home URL
        shouldStartTimer = (webView.url != config.homeURL)
      }
      
      if shouldStartTimer {
        timer = Timer.scheduledTimer(timeInterval: TimeInterval(config.resetTimer), target: self, selector: #selector(fireTimer), userInfo: nil, repeats: false)
        startWarningTimer()
      }
    }
    
  }

  // version 2.8.5
  func resetSession() {
    timer?.invalidate()
    
    guard let webView = webView else { return }
    
    // Remove all additional webViews first
    for additionalWebView in additionalWebViews {
      additionalWebView.stopLoading()
      additionalWebView.removeFromSuperview()
    }
    additionalWebViews.removeAll()
    
    // Clear sessionStorage, localStorage, and cookies using JavaScript
    let javascript = """
    if (typeof sessionStorage !== 'undefined') {
        sessionStorage.clear();
    }
    if (typeof localStorage !== 'undefined') {
        localStorage.clear();
    }
    if (typeof document.cookie !== 'undefined') {
        document.cookie.split(";").forEach(function(c) {
            document.cookie = c.replace(/^ +/, "").replace(/=.*/, "=;expires=" + new Date().toUTCString() + ";path=/");
        });
    }
    """
    
    let generation = configurationGeneration
    webView.evaluateJavaScript(javascript) { (_, _) in
      guard self.configurationGeneration == generation else { return }
      
      // Clear WKWebView website data store (this is crucial for Microsoft login)
      let websiteDataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
      let dataStore = webView.configuration.websiteDataStore
      
      dataStore.removeData(ofTypes: websiteDataTypes, modifiedSince: Date(timeIntervalSince1970: 0)) {
        
        // Load home URL after clearing data
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
          guard self.configurationGeneration == generation, self.kioskConfiguration != nil else { return }
          self.config.newURL = self.config.homeURL
          self.loadWebViewIfNeeded()
        }
      }
    }
  }
  
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    hideLoadingIndicator()
    let failure = error as NSError
    guard isCurrentBrowser(webView), kioskConfiguration != nil,
          !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled),
          !(failure.domain == "WebKitErrorDomain" && failure.code == 102) else { return }
    let transientErrors = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                           NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                           NSURLErrorDNSLookupFailed]
    guard failure.domain == NSURLErrorDomain, transientErrors.contains(failure.code) else {
      showConfigurationMessage("The page could not be loaded securely. Contact IT.")
      return
    }
    showConfigurationMessage("Network unavailable. Retrying…")
    let generation = configurationGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak webView] in
      guard let self = self, let webView = webView,
            self.configurationGeneration == generation,
            let home = self.kioskConfiguration?.homeURL else { return }
      self.configurationMessage?.isHidden = true
      webView.load(URLRequest(url: home))
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    self.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard isCurrentBrowser(webView), let home = kioskConfiguration?.homeURL else { return }
    webView.load(URLRequest(url: home))
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    guard isCurrentBrowser(webView), let url = navigationAction.request.url, kioskConfiguration?.permits(url) == true else { return nil }
    if config.redirect == "ON" {
      webView.load(navigationAction.request)
    } else if config.redirect == "ALT", additionalWebViews.count < 3 {
      let popup = WKWebView(frame: webView.frame, configuration: configuration)
      popup.uiDelegate = self
      popup.navigationDelegate = self
      webView.superview?.addSubview(popup)
      additionalWebViews.append(popup)
      return popup
    }
    return nil
  }

  func webViewDidClose(_ webView: WKWebView) {
    guard additionalWebViews.contains(where: { $0 === webView }) else { return }
    webView.stopLoading()
    webView.removeFromSuperview()
    additionalWebViews.removeAll { $0 === webView }
  }

  func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
               completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    // Never override system certificate validation, regardless of legacy DISABLE_TRUST settings.
    completionHandler(.performDefaultHandling, nil)
  }

  // MARK: - User-activity detection (touch / pan / tap anywhere in the view)
  // version 2.8.5
  private func addUserActivityDetection() {
    // We add recognisers only once.
    guard view.gestureRecognizers?.contains(where: { $0.name == "userActivity" }) != true else { return }
    
    let tap = UITapGestureRecognizer(target: self, action: #selector(userDidInteract))
    tap.cancelsTouchesInView = false
    tap.name = "userActivity"
    tap.delegate = self
    
    let pan = UIPanGestureRecognizer(target: self, action: #selector(userDidInteract))
    pan.cancelsTouchesInView = false
    pan.name = "userActivity"
    pan.delegate = self
    
    view.addGestureRecognizer(tap)
    view.addGestureRecognizer(pan)
  }
  
  @objc private func userDidInteract() {
    
    // Check if warning banner is currently visible
    let warningBannerVisible = warningBannerView?.isHidden == false && warningBannerView?.alpha ?? 0 > 0
    
    // Reset timers if:
    // 1. detectScroll is ON (existing behavior), OR
    // 2. Warning banner is visible (user should be able to dismiss by interacting)
    if (config.detectScroll == "ON" || warningBannerVisible), config.resetTimer != 0 {
      timer?.invalidate()
      cancelWarningTimer()
      
      // Check if we should start timer based on current URL and resetTimerOnHome setting
      let shouldStartTimer: Bool
      if config.resetTimerOnHome == "ON" {
        // When resetTimerOnHome is ON, always start the timer regardless of URL
        shouldStartTimer = true
      } else {
        // Default behavior: only start timer when NOT at home URL
        shouldStartTimer = (webView?.url != config.homeURL)
      }
      
      if shouldStartTimer {
        timer = Timer.scheduledTimer(timeInterval: TimeInterval(config.resetTimer),
                                     target: self,
                                     selector: #selector(fireTimer),
                                     userInfo: nil,
                                     repeats: false)
        startWarningTimer()
      }
    }
  }
  
  // Allow our gesture recognisers to work alongside the web view's own recognisers.
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                         shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    return true
  }
  
  // MARK: - Device Lock Detection
  private func addDeviceLockDetection() {
    // Listen for device lock events
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(deviceDidLock),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(deviceDidUnlock),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
    
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(deviceWillLock),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
  }
  
  @objc private func deviceWillLock() {
    // Pause any ongoing operations, timers, etc.
    timer?.invalidate()
    resumeAfterInterruption = webView?.isLoading == true
    webView?.stopLoading()
  }
  
  @objc private func deviceDidLock() {
    // Additional cleanup when device is locked
    // This could trigger session reset, clear sensitive data, etc.
    if config.resetTimer != 0 {
      // Reset session immediately on device lock if timer is enabled
      DispatchQueue.main.async {
        self.resetSession()
      }
    }
  }
  
  @objc private func deviceDidUnlock() {
    readManagedAppConfig()
    if resumeAfterInterruption, kioskConfiguration != nil {
      resumeAfterInterruption = false
      loadWebViewIfNeeded()
    }
  }
  
  // Clean up when view controller is deallocated
  deinit {
    if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer) }
    // Remove device lock observers
    NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
    NotificationCenter.default.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
    webView?.removeFromSuperview()
    webView = nil
  }
}


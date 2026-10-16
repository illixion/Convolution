/*
 Hypnos - a pointer for web pages on Apple TV (sideload builds only)

 Ported from web-yt-dlp's player (`TVWebCursor.swift`, removed in 5aae2c7),
 itself after tvOS-Browser's `ViewController.m`: the Siri Remote's touch
 surface moves a pointer over a `UIWebView`, a click presses what is under
 it, and a text field opens the system keyboard and writes the result back.
 Every hover check and click looks the element up again at that moment
 (`document.elementFromPoint`), so a page that changes under the pointer
 never gets a stale element pressed. Double-click switches to scrolling.
 */

#if HYPNOS_YOUTUBE && os(tvOS)

import GameController
import SwiftUI
import UIKit

struct TVWebCursorView: UIViewControllerRepresentable {
    let webView: UIView
    let evaluate: (String) -> String?

    func makeUIViewController(context _: Context) -> TVWebCursorViewController {
        TVWebCursorViewController(webView: webView, evaluate: evaluate)
    }

    func updateUIViewController(_: TVWebCursorViewController, context _: Context) {}
}

/// A `GCEventViewController` so the touch surface arrives as touches here
/// rather than as focus moves.
final class TVWebCursorViewController: GCEventViewController {
    private let webView: UIView
    private let evaluate: (String) -> String?
    private let cursor = UIView()
    private var lastTouchLocation: CGPoint?
    /// Pointer mode drives the page; scroll mode hands the touch surface to
    /// the web view's own scrolling.
    private var isCursorMode = true

    init(webView: UIView, evaluate: @escaping (String) -> String?) {
        self.webView = webView
        self.evaluate = evaluate
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.frame = view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)

        cursor.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
        cursor.center = view.center
        cursor.backgroundColor = .white
        cursor.layer.cornerRadius = 14
        cursor.layer.borderWidth = 2
        cursor.layer.borderColor = UIColor.black.withAlphaComponent(0.35).cgColor
        cursor.layer.shadowColor = UIColor.black.cgColor
        cursor.layer.shadowOpacity = 0.4
        cursor.layer.shadowRadius = 6
        cursor.layer.shadowOffset = CGSize(width: 0, height: 2)
        cursor.isUserInteractionEnabled = false
        view.addSubview(cursor)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleMode))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        view.addGestureRecognizer(doubleTap)

        applyMode()
    }

    @objc private func toggleMode() {
        isCursorMode.toggle()
        applyMode()
    }

    private func applyMode() {
        webView.isUserInteractionEnabled = !isCursorMode
        cursor.isHidden = !isCursorMode
    }

    // MARK: - Pointer

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isCursorMode else { return super.touchesBegan(touches, with: event) }
        lastTouchLocation = nil
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isCursorMode, let touch = touches.first else { return super.touchesMoved(touches, with: event) }
        let location = touch.location(in: view)
        defer { lastTouchLocation = location }
        // The first sample of a swipe only sets where it started.
        guard let last = lastTouchLocation else { return }
        var frame = cursor.frame
        frame.origin.x = min(max(frame.origin.x + location.x - last.x, 0), view.bounds.width - frame.width)
        frame.origin.y = min(max(frame.origin.y + location.y - last.y, 0), view.bounds.height - frame.height)
        cursor.frame = frame
        updateHoverAppearance()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isCursorMode else { return super.touchesEnded(touches, with: event) }
        lastTouchLocation = nil
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isCursorMode, presses.contains(where: { $0.type == .select }) else {
            return super.pressesEnded(presses, with: event)
        }
        activateElementUnderCursor()
    }

    /// The pointer's centre in the page's coordinates (the page may be laid
    /// out wider than the view, at `window.innerWidth`).
    private func pagePoint() -> CGPoint? {
        guard let text = evaluate("window.innerWidth"), let innerWidth = Double(text), innerWidth > 0 else { return nil }
        let scale = webView.bounds.width / innerWidth
        guard scale > 0 else { return nil }
        return CGPoint(x: cursor.center.x / scale, y: cursor.center.y / scale)
    }

    private func updateHoverAppearance() {
        guard let point = pagePoint() else { return }
        let isClickable = evaluate("""
        (() => {
          const el = document.elementFromPoint(\(Int(point.x)), \(Int(point.y)));
          return el && el.closest('a,input,textarea,button,[onclick],[role=button],[tabindex]') ? 'true' : 'false';
        })();
        """) == "true"
        cursor.backgroundColor = isClickable ? .systemRed : .white
        cursor.transform = isClickable ? CGAffineTransform(scaleX: 1.3, y: 1.3) : .identity
    }

    private struct Field: Decodable {
        let isTextField: Bool
        let type: String
        let value: String
        let placeholder: String
    }

    private func activateElementUnderCursor() {
        guard let point = pagePoint() else { return }
        let x = Int(point.x)
        let y = Int(point.y)
        guard let raw = evaluate("""
        (() => {
          const el = document.elementFromPoint(\(x), \(y));
          if (!el) return 'null';
          const tag = (el.tagName || '').toLowerCase();
          const type = (el.type || '').toLowerCase();
          const textLike = ['date','datetime','email','number','password','search','tel','text','time','url','week'];
          return JSON.stringify({
            isTextField: (tag === 'input' && (type === '' || textLike.includes(type))) || tag === 'textarea',
            type: type || 'text',
            value: el.value || '',
            placeholder: el.getAttribute('aria-label') || el.placeholder || el.title || ''
          });
        })();
        """), let data = raw.data(using: .utf8),
            let field = try? JSONDecoder().decode(Field.self, from: data), field.isTextField else {
            _ = evaluate("document.elementFromPoint(\(x), \(y))?.click();")
            return
        }
        presentTextInput(for: field, x: x, y: y)
    }

    private func presentTextInput(for field: Field, x: Int, y: Int) {
        let alert = UIAlertController(title: field.placeholder.isEmpty ? "Enter Text" : field.placeholder,
                                      message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.text = field.type == "password" ? "" : field.value
            textField.placeholder = field.placeholder
            switch field.type {
            case "url": textField.keyboardType = .URL
            case "email": textField.keyboardType = .emailAddress
            case "number", "tel": textField.keyboardType = .numbersAndPunctuation
            case "password":
                textField.isSecureTextEntry = true
                textField.textContentType = .password
            default: break
            }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Done", style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text else { return }
            self?.writeBack(text, x: x, y: y, pressEnter: false)
        })
        alert.addAction(UIAlertAction(title: "Next", style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text else { return }
            self?.writeBack(text, x: x, y: y, pressEnter: true)
        })
        present(alert, animated: true)
    }

    /// Writes the text into the field and fires the events a script-driven
    /// form listens for. The text goes in as a JSON literal, so a quote in a
    /// password can't end the string early. "Next" also presses Enter in the
    /// field, which Google's sign-in steps listen for; the page's own Next
    /// button works with the pointer too.
    private func writeBack(_ text: String, x: Int, y: Int, pressEnter: Bool) {
        let literal = (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let enter = pressEnter ? """
          for (const type of ['keydown', 'keypress', 'keyup']) {
            el.dispatchEvent(new KeyboardEvent(type, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
          }
        """ : ""
        _ = evaluate("""
        (() => {
          const el = document.elementFromPoint(\(x), \(y));
          if (!el) return;
          el.focus();
          const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value')?.set;
          setter ? setter.call(el, \(literal)) : (el.value = \(literal));
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          \(enter)
        })();
        """)
    }
}

#endif

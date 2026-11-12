import SwiftUI
import SwiftData
import UIKit
import Observation
@preconcurrency import StripePaymentSheet

/// Paying for an order in the app: Stripe's PaymentSheet. The server makes one PaymentIntent per
/// order and hands back the same one when asked again, so retrying can't charge twice.
enum InAppPay {
    /// Apple Pay needs the in-app payments entitlement (with the merchant id) on the App ID and in its
    /// provisioning profile. Until a build carries it, PaymentSheet offers cards only, even when the
    /// server names a merchant id. Turn this on in the same change that adds the entitlement.
    static let applePayEntitled = false

    static func sheet(for p: PaymentDTO) -> PaymentSheet? {
        guard let secret = p.clientSecret else { return nil }
        var config = PaymentSheet.Configuration()
        config.merchantDisplayName = p.merchantName
        config.apiClient = STPAPIClient(publishableKey: p.publishableKey)
        config.allowsDelayedPaymentMethods = false
        if applePayEntitled, let merchant = p.merchantId, !merchant.isEmpty {
            config.applePay = .init(merchantId: merchant, merchantCountryCode: p.country)
        }
        return PaymentSheet(paymentIntentClientSecret: secret, configuration: config)
    }
}

/// One order's trip through PaymentSheet: ask the server for the payment, show the sheet, and when it
/// finishes, read the order back (paid, with its code and the address).
@Observable
final class PayFlow {
    var sheet: PaymentSheet?
    var presenting = false
    var working = false
    var problem: String?
    @ObservationIgnored private var order: Order?

    func pay(_ order: Order, context: ModelContext) async {
        working = true
        defer { working = false }
        do {
            let p = try await Sync.checkout(order)
            if p.payment == PaymentState.paid.rawValue {
                try await Sync.refresh(order: order, context: context)
                return
            }
            guard let s = InAppPay.sheet(for: p) else { return }
            self.order = order
            sheet = s
            presenting = true
        } catch {
            problem = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    func finished(_ result: PaymentSheetResult, context: ModelContext) async {
        presenting = false
        guard let order else { return }
        switch result {
        case .completed:
            working = true
            defer { working = false }
            // The server asks Stripe if its webhook hasn't come yet; once more after a beat if needed.
            for attempt in 0..<3 {
                try? await Sync.refresh(order: order, context: context)
                if order.payment == .paid { break }
                try? await Task.sleep(for: .seconds(attempt + 1))
            }
            if order.payment != .paid {
                problem = "Your payment went through, but the server hasn't caught up. It'll show as paid shortly."
            }
        case .canceled:
            break
        case .failed(let error):
            problem = error.localizedDescription
        }
    }
}

extension View {
    /// Shows PaymentSheet when `checkout` has one ready.
    func checkoutSheet(_ checkout: PayFlow, context: ModelContext) -> some View {
        modifier(CheckoutSheet(checkout: checkout, context: context))
    }
}

private struct CheckoutSheet: ViewModifier {
    @Bindable var checkout: PayFlow
    var context: ModelContext

    func body(content: Content) -> some View {
        content.background {
            if let sheet = checkout.sheet {
                Color.clear.paymentSheet(isPresented: $checkout.presenting, paymentSheet: sheet) { result in
                    Task { await checkout.finished(result, context: context) }
                }
            }
        }
    }
}

// MARK: Photos

/// A photo ready to send: about 1200 px on the long side (`PhotoPrep`), as a JPEG.
enum PhotoJPEG {
    static func make(_ image: UIImage, quality: CGFloat = 0.8) -> Data? {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let size = PhotoPrep.fit(pixels)
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.jpegData(withCompressionQuality: quality) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// The camera, for "Sell something". Falls back to nothing on a device without one (the simulator).
struct CameraPicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage { parent.onPick(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// A batch's photo from the server, or a warm placeholder while it loads (or if there isn't one).
struct BatchPhoto: View {
    var path: String?
    var title: String
    var height: CGFloat
    var radius: CGFloat = 0

    var body: some View {
        let hue = KitchenLook.hue(for: title)
        Color(hue: hue, saturation: 0.35, brightness: 0.85)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .overlay {
                AsyncImage(url: APIConfig.resolve(path)) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "fork.knife")
                            .font(.system(size: height * 0.18, weight: .light))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .clipShape(.rect(cornerRadius: radius))
            .accessibilityLabel(path == nil ? "No photo" : "Photo of \(title)")
    }
}

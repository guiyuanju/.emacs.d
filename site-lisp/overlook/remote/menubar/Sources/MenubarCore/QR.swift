import CoreGraphics
import CoreImage
import Foundation

/// A QR code of text, scale pixels per module, black on white with a four-module quiet zone; nil if it cannot be made.
public func qrCode(_ text: String, scale: Int) -> CGImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(text.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let code = filter.outputImage else { return nil }
    let s = CGFloat(max(scale, 1))
    let scaled = code.samplingNearest().transformed(by: CGAffineTransform(scaleX: s, y: s))
    let margin = 4 * s
    let canvas = scaled.extent.insetBy(dx: -margin, dy: -margin)
    let image = scaled.composited(over: CIImage(color: .white).cropped(to: canvas))
    return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(image, from: canvas)
}

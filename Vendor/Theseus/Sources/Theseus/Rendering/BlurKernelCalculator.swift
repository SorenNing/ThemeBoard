import Foundation
import Metal

/// Computes and caches blur kernel weights for Metal shader passes
final class BlurKernelCalculator {

    private let device: MTLDevice
    private var weightsBufferCache: MTLBuffer?
    private var lastComputedRadius: Int?
    private var lastComputedSigma: Float?

    init(device: MTLDevice) {
        self.device = device
    }

    func weightsBuffer(radius: Int, sigma: Float) -> MTLBuffer? {
        // Check cache validity - use exact match for sigma since it's user-provided
        if let cachedRadius = lastComputedRadius,
           let cachedSigma = lastComputedSigma,
           radius == cachedRadius && sigma == cachedSigma {
            return weightsBufferCache
        }

        let weights = calculateWeights(radius: radius, sigma: sigma)

        weightsBufferCache = device.makeBuffer(
            bytes: weights,
            length: MemoryLayout<Float>.stride * weights.count,
            options: .storageModeShared
        )

        lastComputedRadius = radius
        lastComputedSigma = sigma

        return weightsBufferCache
    }

    func calculateWeights(radius: Int, sigma: Float) -> [Float] {
        guard radius > 0 && sigma > 0 else {
            return [1.0]
        }

        var weights = [Float](repeating: 0, count: radius + 1)
        // Precompute inverse for multiplication instead of division
        let inverseTwoSigmaSquared = 1.0 / (2.0 * sigma * sigma)

        // First pass: compute raw Gaussian weights
        for i in 0...radius {
            let x = Float(i)
            let xSquared = x * x
            weights[i] = exp(-xSquared * inverseTwoSigmaSquared)
        }

        // Sum for normalization: center weight once, symmetric pairs doubled
        var sum = weights[0]
        for i in 1...radius {
            sum += weights[i] * 2
        }

        // Normalize weights
        let inverseSum = 1.0 / sum
        for i in 0...radius {
            weights[i] *= inverseSum
        }

        return weights
    }

    func invalidateCache() {
        weightsBufferCache = nil
        lastComputedRadius = nil
        lastComputedSigma = nil
    }
}

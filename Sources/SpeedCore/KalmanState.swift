import Foundation

/// x = [speed, longitudinal acceleration, accelerometer bias].
struct KalmanState {
    var x: [Double]
    var p: [[Double]]
    var time: Double

    init(speed: Double, acceleration: Double, variance: Double, time: Double) {
        x = [speed, acceleration, 0]
        p = [[variance, 0, 0], [0, 9, 0], [0, 0, 0.25]]
        self.time = time
    }

    mutating func predict(to timestamp: Double, jerkNoise: Double = 0.2) {
        let dt = timestamp - time
        guard dt > 0 else { return }
        let f = [[1.0, dt, 0], [0, 1, 0], [0, 0, 1]]
        x[0] += x[1] * dt
        // Continuous white jerk PSD; exact integral for the constant-a model.
        let q = jerkNoise
        let noise = [[q*dt*dt*dt/3, q*dt*dt/2, 0],
                     [q*dt*dt/2, q*dt, 0], [0, 0, 0.0004*dt]]
        var predicted = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        for i in 0..<3 { for j in 0..<3 {
            for k in 0..<3 { for l in 0..<3 { predicted[i][j] += f[i][k]*p[k][l]*f[j][l] } }
            predicted[i][j] += noise[i][j]
        } }
        p = predicted
        constrain()
        time = timestamp
    }

    func innovation(_ value: Double, h: [Double], variance: Double) -> (residual: Double, variance: Double) {
        let predicted = zip(x, h).reduce(0) { $0 + $1.0 * $1.1 }
        var s = variance
        for i in 0..<3 { for j in 0..<3 { s += h[i]*p[i][j]*h[j] } }
        return (value - predicted, s)
    }

    mutating func update(_ value: Double, h: [Double], variance: Double) {
        let (r, s) = innovation(value, h: h, variance: variance)
        guard s.isFinite, s > 0 else { return }
        var k = [0.0, 0, 0]
        for i in 0..<3 { for j in 0..<3 { k[i] += p[i][j]*h[j]/s } }
        for i in 0..<3 { x[i] += k[i]*r }
        // Joseph form: (I-KH)P(I-KH)' + KRK'.
        var a = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        for i in 0..<3 { for j in 0..<3 { a[i][j] = (i == j ? 1 : 0) - k[i]*h[j] } }
        var next = a
        for i in 0..<3 { for j in 0..<3 {
            next[i][j] = k[i]*variance*k[j]
            for m in 0..<3 { for n in 0..<3 { next[i][j] += a[i][m]*p[m][n]*a[j][n] } }
        } }
        for i in 0..<3 { for j in 0..<3 { p[i][j] = (next[i][j] + next[j][i])/2 } }
        constrain()
    }

    mutating func constrain() {
        if x[0] < 0 {
            x[0] = 0
            // Speed is a magnitude: don't integrate braking through zero into reverse travel.
            if x[1] < 0 { x[1] = 0 }
        }
        x[1] = min(12, max(-12, x[1]))
        for i in 0..<3 { p[i][i] = max(1e-9, p[i][i]) }
    }
}

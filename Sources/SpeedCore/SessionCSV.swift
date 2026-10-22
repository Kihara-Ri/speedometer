import Foundation

extension SessionReport {
    /// Full analysis samples, not reduced chart points. High-rate raw samples remain in JSONL.
    public func writeCSV(to url: URL) throws {
        try Data([0xEF, 0xBB, 0xBF]).write(to: url)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        let columns = ["elapsed_s", "uptime_s", "speed_mps", "uncertainty_mps", "state", "source", "observation_age_s",
            "covered_distance_m", "model_acceleration_mps2", "bias_mps2", "innovation", "nis", "reported_speed_accuracy_mps",
            "uncertainty_floor_mps", "covariance_speed_sigma_mps", "latitude", "longitude", "altitude_m", "course_deg",
            "raw_speed_mps", "raw_speed_timestamp", "horizontal_accuracy_m", "motion_timestamp"] +
            ["user_ax_g", "user_ay_g", "user_az_g", "gravity_x_g", "gravity_y_g", "gravity_z_g", "rotation_x_radps", "rotation_y_radps", "rotation_z_radps",
             "quaternion_x", "quaternion_y", "quaternion_z", "quaternion_w", "accelerometer_timestamp", "raw_ax_g", "raw_ay_g", "raw_az_g",
             "gyroscope_timestamp", "raw_gx_radps", "raw_gy_radps", "raw_gz_radps", "magnetometer_timestamp", "mag_x_uT", "mag_y_uT", "mag_z_uT",
             "pressure_kPa", "relative_altitude_m", "battery_fraction", "thermal_state"] +
            (0..<3).flatMap { row in (0..<3).map { "P\(row)\($0)" } }
        try file.write(contentsOf: Data((columns.joined(separator: ",") + "\n").utf8))
        func number(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "" }; return String(value)
        }
        func vector(_ values: [Double]?, count: Int) -> [String] {
            (0..<count).map { index in number(values.flatMap { index < $0.count ? $0[index] : nil }) }
        }
        for (index, sample) in samples.enumerated() {
            if index % 1000 == 0 { try Task.checkCancellation() }
            let diag = sample.diagnostics
            var row = [number(sample.timestamp - startTime), number(sample.timestamp), number(sample.speed), number(sample.uncertainty),
                sample.state.rawValue, sample.source.rawValue, number(sample.observationAge), number(sample.cumulativeMeters),
                number(diag?.state?[1]), number(diag?.state?[2]), number(diag?.innovation), number(diag?.nis), number(diag?.reportedSpeedAccuracy),
                number(diag?.uncertaintyFloor), number(diag?.covarianceSpeedSigma), number(sample.location?.latitude), number(sample.location?.longitude),
                number(sample.location?.altitude), number(sample.location?.course), number(sample.rawSpeed?.speed), number(sample.rawSpeed?.timestamp),
                number(sample.rawSpeed?.horizontalAccuracy), number(sample.motion?.timestamp)]
            row += vector(sample.motion?.acceleration, count: 3)
            row += vector(sample.motion?.gravity, count: 3)
            row += vector(sample.motion?.rotationRate, count: 3)
            row += vector(sample.motion?.quaternion, count: 4)
            row += [number(sample.accelerometer?.timestamp)] + vector(sample.accelerometer?.values, count: 3)
            row += [number(sample.gyroscope?.timestamp)] + vector(sample.gyroscope?.values, count: 3)
            row += [number(sample.magnetometer?.timestamp)] + vector(sample.magnetometer?.values, count: 3)
            row += [number(sample.pressure), number(sample.relativeAltitude), number(sample.batteryLevel.map(Double.init)), sample.thermalState.map(String.init) ?? ""]
            for i in 0..<3 { row += vector(diag?.covariance.flatMap { i < $0.count ? $0[i] : nil }, count: 3) }
            try file.write(contentsOf: Data((row.joined(separator: ",") + "\n").utf8))
        }
        try file.synchronize()
    }
}

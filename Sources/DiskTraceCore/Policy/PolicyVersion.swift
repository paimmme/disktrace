import Foundation

/// Identifies the alert-rule revision recorded on every `AlertDecision`, so a
/// decision can always be explained against the rules that produced it.
public enum AlertPolicyVersion {
    public static let current = "disktrace-policy-1.0.0"
}

import Foundation

/// Identifies the alert-rule revision recorded on every `AlertDecision`, so a
/// decision can always be explained against the rules that produced it.
public enum AlertPolicyVersion {
    public static let current = "disktrace-policy-1.0.0"
}

/// Evidence schema version stamped onto file changes and task links, so late
/// evidence can be added as a new version without rewriting original facts.
public enum EvidenceVersion {
    public static let current = 1
}

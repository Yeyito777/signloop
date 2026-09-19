"""Signer-independent, on-device isolated-sign recognition research + reference engine.

Everything here operates on hand-landmark sequences. No images are read, stored or
uploaded. The Python code is the reference implementation for the Swift engine in
ios/Signloop/SignEngine*.swift; parity is checked with golden vectors.
"""

SCHEMA_VERSION = 1

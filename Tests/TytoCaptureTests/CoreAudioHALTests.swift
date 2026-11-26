import Testing
@testable import TytoCapture

@Suite struct CoreAudioHALTests {
    @Test func fourCharCodeRendersPrintableCodes() {
        // 'nope' — the status a denied HAL call is most likely to return.
        #expect(CoreAudioHAL.fourCharCode(0x6E6F_7065) == "'nope'")
    }

    @Test func fourCharCodeFallsBackToDecimal() {
        #expect(CoreAudioHAL.fourCharCode(1) == "1")
    }

    @Test func describeTreatsNoErrAsOK() {
        #expect(CoreAudioHAL.describe(0) == "ok")
    }
}

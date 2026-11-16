import Testing
@testable import AccessoryReproCore

@Suite struct ReproStateTests {
    @Test func noOperationsBeforeAttachment() {
        var state = ReproState()
        for operation in [ReproState.Operation.claim, .close, .reopen] {
            #expect(throws: ReproError.self) { try state.begin(operation) }
        }
    }
    @Test func oneOrderedClaimCloseReopen() throws {
        var state = ReproState()
        state.attach(registryID: 17)
        for operation in [ReproState.Operation.claim, .close, .reopen] {
            let token = try state.begin(operation)
            #expect(state.operationInProgress)
            #expect(throws: ReproError.self) { try state.begin(operation) }
            let complete = state.complete(token)
            #expect(complete)
        }
        #expect(state.phase == .finished)
        #expect(!state.canClaim && !state.canClose && !state.canReopen)
    }
    @Test func duplicateConnectDoesNotInvalidateOperation() throws {
        var state = ReproState()
        state.attach(registryID: 17)
        let token = try state.begin(.claim)
        state.attach(registryID: 17)
        let complete = state.complete(token)
        #expect(complete)
    }
    @Test func logicalReconnectDoesNotClearFailureLatch() throws {
        var state = ReproState()
        state.attach(registryID: 17)
        let token = try state.begin(.claim)
        state.detach(registryID: 17)
        state.attach(registryID: 17)
        let complete = state.complete(token)
        #expect(!complete)
        #expect(state.phase == .recoveryRequired)
        #expect(!state.canClaim)
    }
    @Test func newPhysicalRegistryClearsFailureWhenIdle() {
        var state = ReproState()
        state.attach(registryID: 17)
        state.fail("Injected failure")
        state.detach(registryID: 17)
        state.attach(registryID: 18)
        #expect(state.phase == .ready)
        #expect(state.failure == nil)
    }
    @Test func freshRegistryDuringOperationDiscardsOldResult() throws {
        var state = ReproState()
        state.attach(registryID: 17)
        let token = try state.begin(.claim)
        state.attach(registryID: 18)
        let complete = state.complete(token)
        #expect(!complete)
        #expect(state.phase == .recoveryRequired)
    }
    @Test func wrongOrderAndRepeatedReopenAreRejected() throws {
        var state = ReproState()
        state.attach(registryID: 17)
        #expect(throws: ReproError.self) { try state.begin(.reopen) }
        #expect(throws: ReproError.self) { try state.begin(.close) }
        for operation in [ReproState.Operation.claim, .close, .reopen] {
            let token = try state.begin(operation)
            let complete = state.complete(token)
            #expect(complete)
        }
        #expect(throws: ReproError.self) { try state.begin(.reopen) }
    }
    @Test func apiFailureBlocksAllFurtherOperations() throws {
        var state = ReproState()
        state.attach(registryID: 17)
        _ = try state.begin(.claim)
        state.fail("AA open failed")
        for operation in [ReproState.Operation.claim, .close, .reopen] {
            #expect(throws: ReproError.self) { try state.begin(operation) }
        }
    }
    @Test func disconnectAfterCloseDoesNotEnableReopenOnLogicalReconnect() throws {
        var state = ReproState()
        state.attach(registryID: 17)
        for operation in [ReproState.Operation.claim, .close] {
            let token = try state.begin(operation)
            let complete = state.complete(token)
            #expect(complete)
        }
        state.detach(registryID: 17)
        state.attach(registryID: 17)
        #expect(!state.canReopen)
        #expect(state.phase == .recoveryRequired)
    }
    @Test func unrelatedDetachDoesNotInvalidateCurrentOperation() throws {
        var state = ReproState()
        state.attach(registryID: 17)
        let token = try state.begin(.claim)
        state.detach(registryID: 99)
        let complete = state.complete(token)
        #expect(complete)
        #expect(state.phase == .claimed)
    }

    @Test func physicalDisappearanceBeforeCallbackCannotPublishPass() throws {
        var state = ReproState()
        state.attach(registryID: 17)
        let token = try state.begin(.claim)
        let completed = state.complete(token, physicalRegistryPresent: false, returnedRegistryID: 17)
        #expect(!completed)
        #expect(state.phase == .recoveryRequired)
        state.attach(registryID: 17)
        #expect(!state.canClaim)
    }

    @Test func returnedClientMustMatchConfirmedPhysicalInstance() throws {
        var state = ReproState()
        state.attach(registryID: 17)
        let token = try state.begin(.claim)
        let completed = state.complete(token, physicalRegistryPresent: true, returnedRegistryID: 99)
        #expect(!completed)
        #expect(state.phase == .recoveryRequired)
        #expect(!state.canClaim && !state.canClose && !state.canReopen)
    }

    @Test func retainedClosedDeviceBlocksReopenAsInconclusiveControl() throws {
        var state = ReproState()
        state.attach(registryID: 17)
        let claim = try state.begin(.claim)
        let claimed = state.complete(claim)
        #expect(claimed)
        let close = try state.begin(.close)
        let closed = state.complete(close, closedClientReleased: false)
        #expect(!closed)
        #expect(state.phase == .recoveryRequired)
        #expect(state.failure?.contains("inconclusive") == true)
        #expect(!state.canReopen)
        #expect(throws: ReproError.self) { try state.begin(.reopen) }
    }

    @Test func releasedClosedDeviceAllowsExactlyOneReopen() throws {
        var state = ReproState()
        state.attach(registryID: 17)
        let claim = try state.begin(.claim)
        let claimed = state.complete(claim)
        #expect(claimed)
        let close = try state.begin(.close)
        let closed = state.complete(close, closedClientReleased: true)
        #expect(closed && state.canReopen)
        let reopen = try state.begin(.reopen)
        let reopened = state.complete(reopen)
        #expect(reopened)
        #expect(throws: ReproError.self) { try state.begin(.reopen) }
    }
}

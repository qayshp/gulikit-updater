import Foundation
import Testing
@testable import NS58Core

struct NS58AttachmentTrackerTests {
    @Test
    func rejectsOldGenerationAfterDetachAndReattachWithSameRegistryID() {
        var tracker = NS58AttachmentTracker()
        let previous = tracker.attach(registryID: 42)

        tracker.detach(registryID: 42)
        let current = tracker.attach(registryID: 42)

        #expect(current != previous)
        #expect(!tracker.isCurrent(registryID: 42, generation: previous))
        #expect(tracker.isCurrent(registryID: 42, generation: current))
        #expect(tracker.generation(for: 42) == current)
    }

    @Test
    func duplicateAttachPreservesCurrentGeneration() {
        var tracker = NS58AttachmentTracker()
        let first = tracker.attach(registryID: 42)
        let duplicate = tracker.attach(registryID: 42)

        #expect(duplicate == first)
        #expect(tracker.generation(for: 42) == first)
        #expect(tracker.isCurrent(registryID: 42, generation: first))
    }

    @Test
    func otherRegistryIDsHaveIndependentAttachmentLifetimes() {
        var tracker = NS58AttachmentTracker()
        let first = tracker.attach(registryID: 42)
        let other = tracker.attach(registryID: 99)

        tracker.detach(registryID: 42)
        let replacement = tracker.attach(registryID: 42)

        #expect(replacement != first)
        #expect(tracker.generation(for: 99) == other)
        #expect(tracker.isCurrent(registryID: 99, generation: other))
        #expect(!tracker.isCurrent(registryID: 99, generation: first))
    }

    @Test
    func detachInvalidatesGenerationAndLookup() {
        var tracker = NS58AttachmentTracker()
        let generation = tracker.attach(registryID: 42)

        tracker.detach(registryID: 42)

        #expect(tracker.generation(for: 42) == nil)
        #expect(!tracker.isCurrent(registryID: 42, generation: generation))
    }

    @Test
    func detachedOrUnknownRegistryIDIsNeverCurrent() {
        let tracker = NS58AttachmentTracker()

        #expect(tracker.generation(for: 42) == nil)
        #expect(!tracker.isCurrent(registryID: 42, generation: UUID()))
    }

    @Test
    func repeatedOrUnrelatedDetachDoesNotChangeAnotherAttachment() {
        var tracker = NS58AttachmentTracker()
        let generation = tracker.attach(registryID: 42)

        tracker.detach(registryID: 99)
        tracker.detach(registryID: 99)

        #expect(tracker.generation(for: 42) == generation)
        #expect(tracker.isCurrent(registryID: 42, generation: generation))
    }
}

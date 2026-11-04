import difflib,pathlib
repo=pathlib.Path.cwd();out=repo/'.build/watch-test-adjustment';out.mkdir(exist_ok=True);patch=[]
for name in ['ModularDecodeParallelTests.swift','ModularStorageTests.swift']:
 path=pathlib.Path('Tests/SwiftJXLCoreTests')/name;old=(repo/path).read_text();new=old
 if name=='ModularDecodeParallelTests.swift':
  needle='        let defaultResult = try await decoder.decode(data)\n'
  replacement='''        #if os(watchOS)
        // These large fixtures exceed the Watch default budget. Preserve its
        // rejection contract, then compare samples under an explicit profile.
        let requiresGeneralProfile = ["responsive-wide-rgb8", "gray2048-gradient-ans"].contains(name)
        if requiresGeneralProfile {
            do {
                _ = try await decoder.decode(data)
                Issue.record("Oversized fixture unexpectedly fitted the Watch default profile")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
            }
        }
        let defaultResult = try await decoder.decode(data, options: .init(
            resourceLimits: requiresGeneralProfile ? .general : .default))
        #else
'''+needle+'''        #endif
'''
  assert old.count(needle)==1;new=new.replace(needle,replacement)
 else:
  needle='''        let audit = ScalarStorageAudit()
        let result = try await ScalarStorageAudit.$current.withValue(audit) {
'''
  replacement='''        #if os(watchOS)
        // The default decode/encode pipeline for these fixtures exceeds the
        // Watch budget. Check rejection before general-profile correctness.
        let requiresGeneralProfile = ["groups-rgb8", "responsive-wide-rgb8"].contains(name)
        let correctnessLimits: ResourceLimits = requiresGeneralProfile ? .general : .default
        if requiresGeneralProfile {
            let limitedDestination = try ImageDestination.allocate(descriptor: descriptor)
            do {
                let limitedResult = try await Decoder().decode(data, into: limitedDestination)
                let limitedAllocated = try await Decoder().decode(data)
                _ = try await Encoder().encode(limitedResult.image)
                _ = try await Encoder().encode(limitedAllocated.image)
                Issue.record("Large-fixture pipeline unexpectedly fitted the Watch default profile")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
            }
        }
        #endif
'''+needle
  assert new.count(needle)==1;new=new.replace(needle,replacement)
  for needle,replacement in [
  ('            return try await Decoder().decode(data, into: destination)\n','            return try await Decoder().decode(data, into: destination, options: .init(resourceLimits: correctnessLimits))\n'),
  ('        let allocated = try await Decoder().decode(data)\n','        let allocated = try await Decoder().decode(data, options: .init(resourceLimits: correctnessLimits))\n'),
  ('            try await Encoder().encode(result.image)\n','            try await Encoder().encode(result.image, options: .init(resourceLimits: correctnessLimits))\n'),
  ('        let canonicalEncoding = try await Encoder().encode(allocated.image)\n','        let canonicalEncoding = try await Encoder().encode(allocated.image, options: .init(resourceLimits: correctnessLimits))\n')]:
   assert new.count(needle)==1;indent=needle[:len(needle)-len(needle.lstrip())];new=new.replace(needle,indent+'#if os(watchOS)\n'+replacement+indent+'#else\n'+needle+indent+'#endif\n')
 (out/name).write_text(new);patch.extend(difflib.unified_diff(old.splitlines(keepends=True),new.splitlines(keepends=True),fromfile='a/'+str(path),tofile='b/'+str(path)))
(repo/'.build/watch-test-adjustment.patch').write_text(''.join(patch));print('Prepared patch only; live tests unchanged')

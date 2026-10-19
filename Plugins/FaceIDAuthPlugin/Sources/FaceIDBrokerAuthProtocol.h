// Objective-C view of FaceIDBrokerAuthProtocol (Sources/FaceIDCore/XPC/BrokerProtocols.swift),
// exported by FaceIDBroker on com.example.faceid.broker.auth. Selector names are pinned on the
// Swift side with @objc(...), and PluginContractTests check that both files agree.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol FaceIDBrokerAuthProtocol

/// `code` is an AuthResultCode raw value; only 0 (match) unlocks.
/// `sessionOwner` is the uid of the agent that answered (0 unless it matched).
- (void)authenticateWithRequestID:(NSString *)requestID reply:(void (^)(NSInteger code, uint32_t sessionOwner))reply;

- (void)cancelAuthenticationWithRequestID:(NSString *)requestID;

@end

NS_ASSUME_NONNULL_END

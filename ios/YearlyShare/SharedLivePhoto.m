#import "SharedLivePhoto.h"

void YLLoadSharedLivePhoto(NSItemProvider *provider, void (^completion)(PHLivePhoto *, NSError *)) {
    if ([provider canLoadObjectOfClass:PHLivePhoto.class]) {
        [provider loadObjectOfClass:PHLivePhoto.class completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
            completion((PHLivePhoto *)object, error);
        }];
    } else {
        // Photos offers the legacy live-photo item rather than the bundle used by
        // NSItemProviderReading. Its loader inspects the Objective-C block's type:
        // a Swift NSSecureCoding callback does not request a PHLivePhoto object.
        [provider loadItemForTypeIdentifier:@"com.apple.live-photo" options:nil completionHandler:^(PHLivePhoto *photo, NSError *error) {
            completion(photo, error);
        }];
    }
}

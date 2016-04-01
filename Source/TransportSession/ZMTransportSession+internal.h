// 
// Wire
// Copyright (C) 2016 Wire Swiss GmbH
// 
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
// 
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <http://www.gnu.org/licenses/>.
// 


@import ZMCSystem;

#import <ZMTransport/ZMTransportSession.h>
#import "ZMPushChannelConnection.h"
#import "ZMTransportRequestScheduler.h"
#import "ZMTransportPushChannel.h"
#import "ZMAccessTokenHandler.h"


@class ZMTaskIdentifierMap;
@class ZMReachability;
@class ZMAccessToken;



@interface ZMTransportSession ()

- (instancetype)initWithURLSessionSwitch:(ZMURLSessionSwitch *)URLSessionSwitch
                        requestScheduler:(ZMTransportRequestScheduler *)requestScheduler
                       reachabilityClass:(Class)reachabilityClass
                                   queue:(NSOperationQueue *)queue
                                   group:(ZMSDispatchGroup *)group
                                 baseURL:(NSURL *)baseURL
                            websocketURL:(NSURL *)websocketURL
                        pushChannelClass:(Class)pushChannelClass
                           keyValueStore:(id<ZMKeyValueStore>)keyValueStore NS_DESIGNATED_INITIALIZER;
@end



@interface ZMTransportSession (RequestScheduler) <ZMTransportRequestSchedulerSession>
@end


@interface ZMTransportSession (Testing)
- (void)setAccessToken:(ZMAccessToken *)accessToken;
@end



@interface ZMTransportSession (ReachabilityObserver) <ZMReachabilityObserver>

- (void)updateNetworkStatusFromDidReadDataFromNetwork;

@end



/// This protocol allows the ZMTransportSession to handle both ZMTransportRequest and ZMPushChannel as scheduled items.
@protocol ZMTransportRequestSchedulerItemAsRequest <NSObject>

/// If the receiver is a transport request, returns @c self, @c nil otherwise
@property (nonatomic, readonly) ZMTransportRequest *transportRequest;
/// If the receiver is a request to open the push channel
@property (nonatomic, readonly) BOOL isPushChannelRequest;

@end



@interface ZMOpenPushChannelRequest : NSObject <ZMTransportRequestSchedulerItem, ZMTransportRequestSchedulerItemAsRequest>
@end



@interface ZMTransportRequest (Scheduler) <ZMTransportRequestSchedulerItem, ZMTransportRequestSchedulerItemAsRequest>
@end


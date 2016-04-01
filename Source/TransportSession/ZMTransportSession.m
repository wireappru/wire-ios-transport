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
@import ZMUtilities;
@import UIKit;

#import "ZMTransportSession+Internal.h"
#import "ZMTransportCodec.h"
#import "ZMAccessToken.h"
#import "ZMTransportRequest+Internal.h"
#import "ZMPersistentCookieStorage.h"
#import "ZMPushChannelConnection.h"
#import "TransportTracing.h"
#import "ZMTaskIdentifierMap.h"
#import "ZMReachability.h"
#import "Collections+ZMTSafeTypes.h"
#import "ZMTransportPushChannel.h"
#import "NSError+ZMTransportSession.h"
#import "ZMUserAgent.h"
#import "ZMURLSession.h"
#import "ZMURLSessionSwitch.h"
#import "ZMBackgroundActivity.h"
#import <libkern/OSAtomic.h>
#import "ZMTLogging.h"
#import "NSData+Multipart.h"


static char* const ZMLogTag ZM_UNUSED = ZMT_LOG_TAG_NETWORK;


NSString * const ZMTransportSessionReachabilityChangedNotificationName = @"ZMTransportSessionReachabilityChanged";

NSString * const ZMTransportSessionNewRequestAvailableNotification = @"ZMTransportSessionNewRequestAvailable";

NSString * const ZMTransportSessionShouldKeepWebsocketOpenNotificationName = @"ZMTransportSessionShouldKeepWebsocketOpenNotification";
NSString * const ZMTransportSessionShouldKeepWebsocketOpenKey = @"shouldKeepWebsocketOpen";

static NSString * const TaskTimerKey = @"task";
static NSString * const SessionTimerKey = @"session";
static NSInteger const DefaultMaximumRequests = 6;


@interface ZMTransportSession () <ZMAccessTokenHandlerDelegate, ZMTimerClient>
{
    // This needs to be an instance variable such that we can use OSAtomic{Increment,Decrement} on it.
    int32_t _numberOfRequestsInProgress;
}

@property (nonatomic) Class pushChannelClass;
@property (nonatomic) BOOL applicationIsBackgrounded;
@property (nonatomic) BOOL shouldKeepWebsocketOpen;

@property (atomic) BOOL firstRequestFired;
@property (nonatomic) NSURL *baseURL;
@property (nonatomic) NSURL *websocketURL;
@property (nonatomic) NSOperationQueue *workQueue;
@property (nonatomic) ZMPersistentCookieStorage *cookieStorage;
@property (nonatomic) BOOL tornDown;

@property (nonatomic) ZMTransportPushChannel *pushChannel;

@property (nonatomic, weak) id<ZMPushChannelConsumer> pushChannelConsumer;
@property (nonatomic) id<ZMSGroupQueue> pushChannelGroupQueue;


@property (nonatomic, copy, readonly) NSString *userAgentValue;

@property (nonatomic, readonly) ZMSDispatchGroup *workGroup;
@property (nonatomic, readonly) ZMReachability *reachability;
@property (nonatomic, readonly) ZMTransportRequestScheduler *requestScheduler;

@property (nonatomic) ZMAccessTokenHandler *accessTokenHandler;

@property (nonatomic) NSMutableSet *expiredTasks;
@property (nonatomic) ZMURLSessionSwitch *urlSessionSwitch;
@property (nonatomic, weak) id<ZMNetworkStateDelegate> weakNetworkStateDelegate;


- (void)signUpForNotifications;

@end



@interface ZMTransportSession (URLSessionDelegate) <ZMURLSessionDelegate>
@end



@interface ZMTransportSession (ApplicationStates)

@property (nonatomic, readonly) BOOL isActive;
- (void)updateActivity;
@end



@implementation ZMTransportSession

- (instancetype)init
{
    @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"You should not use -init" userInfo:nil];
    return [self initWithBaseURL:nil websocketURL:nil keyValueStore:nil];
}

+ (void)setUpConfiguration:(NSURLSessionConfiguration *)configuration;
{
    // Don't accept any cookies. We store these ourselves.
    configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
    
    // Turn on HTTP pipelining
    // RFC 2616 recommends no more than 2 connections per host when using pipelining.
    // https://tools.ietf.org/html/rfc2616
    configuration.HTTPShouldUsePipelining = YES;
    configuration.HTTPMaximumConnectionsPerHost = 2;
    
    configuration.TLSMinimumSupportedProtocol = kTLSProtocol12;
    
    configuration.URLCache = nil;
}

+ (NSURLSessionConfiguration *)foregroundSessionConfiguration
{
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    
    // If not data is transmitted for this amount of time for a request, it will time out.
    // <https://wearezeta.atlassian.net/browse/MEC-622>.
    // Note that it is ok for the request to take longer, we just require there to be _some_ data to be transmitted within this time window.
    configuration.timeoutIntervalForRequest = 61;
    
    // This is a conservative (!) upper bound for a requested resource:
    configuration.timeoutIntervalForResource = 12 * 60;
    
    // NB.: that TCP will on it's own retry. We should be very careful not to stop a request too early. It is better for a request to complete after 50 s (on a high latency network) in stead of continuously trying and timing out after 30 s.
    
    [self setUpConfiguration:configuration];
    return configuration;
}

+ (NSURLSessionConfiguration *)backgroundSessionConfiguration
{
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:@"com.wire.zmessaging"];
    [self setUpConfiguration:configuration];
    return configuration;
}

- (instancetype)initWithBaseURL:(NSURL *)baseURL websocketURL:(NSURL *)websocketURL keyValueStore:(id<ZMKeyValueStore>)keyValueStore;
{
    NSOperationQueue *queue = [NSOperationQueue zm_serialQueueWithName:@"ZMTransportSession"];
    ZMSDispatchGroup *group = [ZMSDispatchGroup groupWithLabel:@"ZMTransportSession init"];
    
    ZMURLSession *foregroundSession = [ZMURLSession sessionWithConfiguration:[[self class] foregroundSessionConfiguration] delegate:self delegateQueue:queue];
    ZMURLSession *backgroundSession = [ZMURLSession sessionWithConfiguration:[[self class] backgroundSessionConfiguration] delegate:self delegateQueue:queue];
    
    ZMTransportRequestScheduler *scheduler = [[ZMTransportRequestScheduler alloc] initWithSession:self operationQueue:queue group:group];
    
    ZMURLSessionSwitch *sessionSwitch = [[ZMURLSessionSwitch alloc]
                                         initWithForegroundSession:foregroundSession
                                         backgroundSession:backgroundSession
                                         ];
    
    return [self initWithURLSessionSwitch:sessionSwitch
                         requestScheduler:scheduler
                        reachabilityClass:[ZMReachability class]
                                    queue:queue
                                    group:group
                                  baseURL:baseURL
                             websocketURL:websocketURL
                            keyValueStore:keyValueStore];
}

- (instancetype)initWithURLSessionSwitch:(ZMURLSessionSwitch *)URLSessionSwitch
                        requestScheduler:(ZMTransportRequestScheduler *)requestScheduler
                       reachabilityClass:(Class)reachabilityClass
                                   queue:(NSOperationQueue *)queue
                                   group:(ZMSDispatchGroup *)group
                                 baseURL:(NSURL *)baseURL
                            websocketURL:(NSURL *)websocketURL
                           keyValueStore:(id<ZMKeyValueStore>)keyValueStore
{
    return [self initWithURLSessionSwitch:URLSessionSwitch
                         requestScheduler:requestScheduler
                        reachabilityClass:reachabilityClass
                                    queue:queue
                                    group:group
                                  baseURL:baseURL
                             websocketURL:websocketURL
                         pushChannelClass:nil
                            keyValueStore:keyValueStore];
}


- (instancetype)initWithURLSessionSwitch:(ZMURLSessionSwitch *)URLSessionSwitch
                        requestScheduler:(ZMTransportRequestScheduler *)requestScheduler
                       reachabilityClass:(Class)reachabilityClass
                                   queue:(NSOperationQueue *)queue
                                   group:(ZMSDispatchGroup *)group
                                 baseURL:(NSURL *)baseURL
                            websocketURL:(NSURL *)websocketURL
                        pushChannelClass:(Class)pushChannelClass
                           keyValueStore:(id<ZMKeyValueStore>)keyValueStore;
{
    self = [super init];
    if (self) {
        self.baseURL = baseURL;
        self.websocketURL = websocketURL;
        self.workQueue = queue;
        _workGroup = group;
        self.cookieStorage = [ZMPersistentCookieStorage storageForServerName:baseURL.host];
        self.expiredTasks = [NSMutableSet set];
        self.urlSessionSwitch = URLSessionSwitch;
        
        _requestScheduler = requestScheduler;
        [self setupReachabilityWithClass:reachabilityClass];
        self.requestScheduler.reachability = self.reachability;
        
        self.requestScheduler.schedulerState = ZMTransportRequestSchedulerStateNormal;
        
        if( ! self.reachability.mayBeReachable) {
            [self schedulerWentOffline:self.requestScheduler];
        }
        
        self.maximumConcurrentRequests = DefaultMaximumRequests;
        
        self.firstRequestFired = NO;
        if (pushChannelClass == nil) {
            pushChannelClass = ZMTransportPushChannel.class;
        }
        self.pushChannel = [[pushChannelClass alloc] initWithScheduler:self.requestScheduler userAgentString:[ZMUserAgent userAgentValue] URL:self.websocketURL];
        self.accessTokenHandler = [[ZMAccessTokenHandler alloc] initWithBaseURL:baseURL cookieStorage:self.cookieStorage delegate:self queue:queue group:group backoff:nil keyValueStore:keyValueStore];
        [self signUpForNotifications];
    }
    return self;
}

- (void)tearDown
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [self.reachability tearDown];
    self.tornDown = YES;
    
    [self.pushChannel closeAndRemoveConsumer];
    [self.workGroup enter];
    [self.workQueue addOperationWithBlock:^{
        [self.urlSessionSwitch tearDown];
        [self.workGroup leave];
    }];
}

#if DEBUG
- (void)dealloc
{
    RequireString(self.tornDown, "Did not call tearDown on %p", (__bridge void *) self);
}
#endif

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p> %@ / %@",
            self.class, self,
            self.baseURL, self.websocketURL];
}

- (void)setAccessTokenRenewalFailureHandler:(ZMCompletionHandlerBlock)handler;
{
    [self.accessTokenHandler setAccessTokenRenewalFailureHandler:handler];
    if (self.accessTokenHandler.hasAccessToken) {
        [self.pushChannel scheduleOpenPushChannel];
    }
}

- (void)setAccessTokenRenewalSuccessHandler:(ZMAccessTokenHandlerBlock)handler
{
    [self.accessTokenHandler setAccessTokenRenewalSuccessHandler:handler];
}

- (ZMAccessToken *)accessToken {
    return self.accessTokenHandler.accessToken;
}

- (void)setupReachabilityWithClass:(Class)reachabilityClass
{
    Require(self.reachability == nil);
    RequireString(self.baseURL.host != nil, "Invalid base URL host");
    RequireString(self.websocketURL.host != nil, "Invalid WebSocket URL host");
    
    NSArray *serverNames = @[self.baseURL.host, self.websocketURL.host];
    _reachability = [[reachabilityClass alloc] initWithServerNames:serverNames observer:self queue:self.workQueue group:self.workGroup];
}

- (NSString *)tasksDescription;
{
    return self.urlSessionSwitch.description;
}

- (void)enqueueSearchRequest:(ZMTransportRequest *)searchRequest;
{
    OSAtomicIncrement32Barrier(&_numberOfRequestsInProgress);
    [self enqueueTransportRequest:searchRequest];
}

- (ZMTransportEnqueueResult *)attemptToEnqueueSyncRequestWithGenerator:(ZMTransportRequestGenerator)requestGenerator;
{
    //
    // N.B.: This method needs to be thread safe!
    //
    if (self.tornDown) {
        return [ZMTransportEnqueueResult resultDidHaveLessRequestsThanMax:NO didGenerateNonNullRequest:NO];
    }
    self.firstRequestFired = YES;
    
    int32_t const limit = ((int32_t) MIN(self.maximumConcurrentRequests, self.requestScheduler.concurrentRequestCountLimit));
    int32_t const newCount = OSAtomicIncrement32Barrier(&_numberOfRequestsInProgress);
    if (limit < newCount) {
        ZMLogInfo(@"Reached limit of %d concurrent requests. Not enqueueing.", limit);
        [self decrementNumberOfRequestsInProgressAndNotifyOperationLoop:NO];
        return [ZMTransportEnqueueResult resultDidHaveLessRequestsThanMax:NO didGenerateNonNullRequest:NO];
    } else {
        ZMTransportRequest *request = requestGenerator();
        if (request == nil) {
            [self decrementNumberOfRequestsInProgressAndNotifyOperationLoop:NO];
            return [ZMTransportEnqueueResult resultDidHaveLessRequestsThanMax:YES didGenerateNonNullRequest:NO];
        }
        [self enqueueTransportRequest:request];
        return [ZMTransportEnqueueResult resultDidHaveLessRequestsThanMax:YES didGenerateNonNullRequest:YES];
    }
}

- (void)enqueueTransportRequest:(ZMTransportRequest *)request;
{
    //
    // N.B.: This part of the method needs to be thread safe!
    //
    
    RequireString(request.hasRequiredPayload, "Payload vs. method");
    
    ZM_WEAK(self);
    ZMSDispatchGroup *group = self.workGroup;
    [group enter];
    [self.workQueue addOperationWithBlock:^{
        ZM_STRONG(self);
        [self.requestScheduler addItem:request];
        [group leave];
    }];
}

- (void)sendTransportRequest:(ZMTransportRequest *)request;
{
    NSDate * const expirationDate = request.expirationDate;
    
    // Immediately fail request if it has already expired at this point in time
    if ((expirationDate != nil) && (expirationDate.timeIntervalSinceNow < 0.1)) {
        NSError *error = [NSError errorWithDomain:ZMTransportSessionErrorDomain code:ZMTransportSessionErrorCodeRequestExpired userInfo:nil];
        ZMTransportResponse *expiredResponse = [ZMTransportResponse responseWithTransportSessionError:error];
        [request completeWithResponse:expiredResponse];
        [self decrementNumberOfRequestsInProgressAndNotifyOperationLoop:YES]; // TODO aren't we decrementing too late here?
        return;
    }
    
    // TODO: Need to set up a timer such that we can fail expired requests before they hit this point of the code -> namely when offline
    
    ZMURLSession *session = request.shouldUseOnlyBackgroundSession ? self.urlSessionSwitch.backgroundSession :  self.urlSessionSwitch.currentSession;
    if (session.configuration.timeoutIntervalForRequest < expirationDate.timeIntervalSinceNow) {
        ZMLogWarn(@"May not be able to time out request. timeoutIntervalForRequest (%g) is too low (%g).",
                  session.configuration.timeoutIntervalForRequest, expirationDate.timeIntervalSinceNow);
    }
    
    NSURLSessionTask *task = [self suspendedTaskForRequest:request onSession:session];
    if (expirationDate) { //TODO can we test this if-statement somehow?
        [self startTimeoutForTask:task date:expirationDate onSession:session];
    }
    
    [request markStartOfUploadTimestamp];
    [task resume];
}

- (NSURLSessionTask *)suspendedTaskForRequest:(ZMTransportRequest *)request onSession:(ZMURLSession *)session;
{
    NSURL *url = [NSURL URLWithString:request.path relativeToURL:self.baseURL];
    NSAssert(url != nil, @"Nil URL in request");
    
    NSMutableURLRequest *URLRequest = [[NSMutableURLRequest alloc] initWithURL:url];
    [ZMUserAgent setUserAgentOnRequest:URLRequest];
    [URLRequest setHTTPMethod:request.methodAsString];
    [request setAcceptedResponseMediaTypeOnHTTPRequest:URLRequest];
    [request setBodyDataAndMediaTypeOnHTTPRequest:URLRequest];
    [request setContentDispositionOnHTTPRequest:URLRequest];
    
    [self.accessTokenHandler checkIfRequest:request needsToFetchAccessTokenInURLRequest:URLRequest];
    
    NSData *bodyData = URLRequest.HTTPBody;
    URLRequest.HTTPBody = nil;
    ZMLogInfo(@"----> Request: %@\n%@", URLRequest.allHTTPHeaderFields, request);
    NSURLSessionTask *task = [session taskWithRequest:URLRequest bodyData:(bodyData.length == 0) ? nil : bodyData transportRequest:request];
    return task;
}

- (void)startTimeoutForTask:(NSURLSessionTask *)task date:(NSDate *)date onSession:(ZMURLSession *)session
{
    ZMTimer *timer = [ZMTimer timerWithTarget:self operationQueue:self.workQueue];
    timer.userInfo = @{
                       TaskTimerKey: task,
                       SessionTimerKey: session
                       };
    
    [session setTimeoutTimer:timer forTask:task];
    
    [timer fireAtDate:date];
}


- (void)timerDidFire:(ZMTimer *)timer
{
    NSURLSessionTask *task = timer.userInfo[TaskTimerKey];
    ZMURLSession *session = timer.userInfo[SessionTimerKey];
    [self expireTask:task session:session];
}

- (void)expireTask:(NSURLSessionTask *)task session:(ZMURLSession *)session;
{
    ZMLogDebug(@"Expiring task %lu", (unsigned long) task.taskIdentifier);
    [self.expiredTasks addObject:task]; // Need to make sure it's set before cancelling.
    [session cancelTaskWithIdentifier:task.taskIdentifier completionHandler:^(BOOL didCancel){
        if (! didCancel) {
            ZMLogDebug(@"Removing expired task %lu", (unsigned long) task.taskIdentifier);
            [self.expiredTasks removeObject:task];
        }
    }];
}

- (void)didCompleteRequest:(ZMTransportRequest *)request data:(NSData *)data task:(NSURLSessionTask *)task error:(NSError *)error;
{
    NOT_USED(error);
    [self decrementNumberOfRequestsInProgressAndNotifyOperationLoop:YES]; // TODO aren't we decrementing too late here?
    
    NSHTTPURLResponse *httpResponse = (id) task.response;
    
    BOOL const expired = [self.expiredTasks containsObject:task];
    ZMLogDebug(@"Task %lu is %@", (unsigned long) task.taskIdentifier, expired ? @"expired" : @"NOT expired");
    NSError *transportError = [NSError transportErrorFromURLTask:task expired:expired];
    ZMTransportResponse *response = [self transportResponseFromURLResponse:httpResponse data:data error:transportError];
    ZMLogInfo(@"<---- Response to %@ %@ (status %u): %@", [ZMTransportRequest stringForMethod:request.method], request.path, (unsigned) httpResponse.statusCode, response);
    if (response.result == ZMTransportResponseStatusExpired) {
        [request completeWithResponse:response];
        return;
    }
    
    if (request.responseWillContainAccessToken) {
        //ZMTraceAuthRequestWillContainToken(request.path);
        [self.accessTokenHandler processAccessTokenResponse:response taskIdentifier:task.taskIdentifier];
    }
    
    // If this requests needed authentication, but the access token wasn't valid, fail it:
    if (request.needsAuthentication && (httpResponse.statusCode == 401)) {
        NSError *tryAgainError = [NSError errorWithDomain:ZMTransportSessionErrorDomain code:ZMTransportSessionErrorCodeTryAgainLater userInfo:nil];
        ZMTransportResponse *tryAgainResponse = [ZMTransportResponse responseWithTransportSessionError:tryAgainError];
        [request completeWithResponse:tryAgainResponse];
    } else {
        [request completeWithResponse:response];
    }
}


- (void)decrementNumberOfRequestsInProgressAndNotifyOperationLoop:(BOOL)notify
{
    int32_t const limit = (int32_t) MIN(self.maximumConcurrentRequests, self.requestScheduler.concurrentRequestCountLimit);
    if (OSAtomicDecrement32Barrier(&_numberOfRequestsInProgress) < limit) {
        if (notify) {
            [ZMTransportSession notifyNewRequestsAvailable:self];
        }
    }
}

+ (void)notifyNewRequestsAvailable:(id<NSObject>)sender
{
    [[NSNotificationCenter defaultCenter] postNotificationName:ZMTransportSessionNewRequestAvailableNotification object:sender];
}

- (ZMTransportResponse *)transportResponseFromURLResponse:(NSURLResponse *)URLResponse data:(NSData *)data error:(NSError *)error;
{
    NSHTTPURLResponse *HTTPResponse = (NSHTTPURLResponse *) URLResponse;
    return [[ZMTransportResponse alloc] initWithHTTPURLResponse:HTTPResponse data:data error:error];
}

- (void)processCookieResponse:(NSHTTPURLResponse *)HTTPResponse;
{
    [self.cookieStorage setCookieDataFromResponse:HTTPResponse forURL:HTTPResponse.URL];
}

- (void)handlerDidReceiveAccessToken:(ZMAccessTokenHandler *)handler
{
    NOT_USED(handler);
    [self.requestScheduler sessionDidReceiveAccessToken:self];
    
    [self.pushChannel scheduleOpenPushChannel];
}

@synthesize applicationIsBackgrounded = _applicationIsBackgrounded;
- (void)setApplicationIsBackgrounded:(BOOL)newFlag;
{
    _applicationIsBackgrounded = newFlag;
    [self updateActivity];
}

@synthesize shouldKeepWebsocketOpen = _shouldKeepWebsocketOpen;
- (void)setShouldKeepWebsocketOpen:(BOOL)newFlag;
{
    BOOL const old = self.isActive;
    _shouldKeepWebsocketOpen = newFlag;
    if (old != self.isActive) {
        [self updateActivity];
    }
}

- (void)enterBackground;
{
    ZMBackgroundActivity *enterActivity = [ZMBackgroundActivity beginBackgroundActivityWithName:@"ZMTransportSession.enterBackground"];
    ZMLogInfo(@"<%@: %p> %@", self.class, self, NSStringFromSelector(_cmd));
    NSOperationQueue *queue = self.workQueue;
    ZMSDispatchGroup *group = self.workGroup;
    if ((queue != nil) && (group != nil)) {
        [group enter];
        [queue addOperationWithBlock:^{
            // We need to kick into 'Flush' 1st, to get rid of any items stuck in "5xx back-off":
            self.requestScheduler.schedulerState = ZMTransportRequestSchedulerStateFlush; // TODO MARCO test
            
            self.applicationIsBackgrounded = YES;
            [self.urlSessionSwitch switchToBackgroundSession];
            self.requestScheduler.schedulerState = ZMTransportRequestSchedulerStateNormal; // TODO MARCO test
            [ZMTransportSession notifyNewRequestsAvailable:self]; // TODO MARCO test
            [group leave];
            [enterActivity endActivity];
        }];
    } else {
        [enterActivity endActivity];
    }
}

- (void)enterForeground;
{
    ZMLogInfo(@"<%@: %p> %@", self.class, self, NSStringFromSelector(_cmd));
    NSOperationQueue *queue = self.workQueue;
    ZMSDispatchGroup *group = self.workGroup;
    if ((queue != nil) && (group != nil)) {
        [group enter];
        [queue addOperationWithBlock:^{
            self.applicationIsBackgrounded = NO;
            [self.urlSessionSwitch switchToForegroundSession];
            self.requestScheduler.schedulerState = ZMTransportRequestSchedulerStateNormal; // TODO MARCO test
            [group leave];
        }];
    }
}

- (void)prepareForSuspendedState;
{
    ZMBackgroundActivity *activity = [ZMBackgroundActivity beginBackgroundActivityWithName:@"enqueue access token"];
    [self.urlSessionSwitch.currentSession countTasksWithCompletionHandler:^(NSUInteger count) {
        if (0 < count) {
            [self sendAccessTokenRequest];
        }
        [activity endActivity];
    }];
}

- (void)setNetworkStateDelegate:(id<ZMNetworkStateDelegate>)networkStateDelegate
{
    self.weakNetworkStateDelegate = networkStateDelegate;
    if (!self.reachability.mayBeReachable) {
        [networkStateDelegate didGoOffline];
    }
    else {
        [networkStateDelegate didReceiveData];
    }
}

- (void)shouldKeepWebsocketOpen:(NSNotification *)notification
{
    NSOperationQueue *queue = self.workQueue;
    ZMSDispatchGroup *group = self.workGroup;
    if ((queue != nil) && (group != nil)) {
        [group enter];
        [queue addOperationWithBlock:^{
            self.shouldKeepWebsocketOpen = [notification.userInfo[ZMTransportSessionShouldKeepWebsocketOpenKey] boolValue];
            [group leave];
        }];
    }
}

- (void)signUpForNotifications;
{
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(shouldKeepWebsocketOpen:) name:ZMTransportSessionShouldKeepWebsocketOpenNotificationName object:nil];
}


@end



@implementation ZMTransportSession (RequestScheduler)

@dynamic reachability;


- (void)sendAccessTokenRequest;
{
    [self.accessTokenHandler sendAccessTokenRequestWithURLSession:self.urlSessionSwitch.foregroundSession];
}

- (BOOL)accessTokenIsAboutToExpire {
    return [self.accessTokenHandler accessTokenIsAboutToExpire];
}

- (BOOL)canStartRequestWithAccessToken;
{
    return [self.accessTokenHandler canStartRequestWithAccessToken];
}


- (void)sendSchedulerItem:(id<ZMTransportRequestSchedulerItemAsRequest>)item;
{
    if (item.isPushChannelRequest) {
        if (self.accessTokenHandler.hasAccessToken && self.isActive) {
            [self.pushChannel createPushChannelWithAccessToken:self.accessToken clientID:self.clientID];
        }
    } else {
        [self sendTransportRequest:item.transportRequest];
    }
}

- (void)temporarilyRejectSchedulerItem:(id<ZMTransportRequestSchedulerItemAsRequest>)item;
{
    ZMTransportRequest *request = item.transportRequest;
    if (request != nil) {
        NSError *error = [NSError errorWithDomain:ZMTransportSessionErrorDomain code:ZMTransportSessionErrorCodeTryAgainLater userInfo:nil];
        ZMTransportResponse *tryAgainRespose = [ZMTransportResponse responseWithTransportSessionError:error];
        [request completeWithResponse:tryAgainRespose];
        [self decrementNumberOfRequestsInProgressAndNotifyOperationLoop:YES];
    }
}

- (void)schedulerIncreasedMaximumNumberOfConcurrentRequests:(ZMTransportRequestScheduler *)scheduler;
{
    ZMLogDebug(@"%@ Notify new request" , NSStringFromSelector(_cmd));
    [self.pushChannel scheduleOpenPushChannel];
    [ZMTransportSession notifyNewRequestsAvailable:scheduler];
}

- (void)schedulerWentOffline:(ZMTransportRequestScheduler *)scheduler
{
    NOT_USED(scheduler);
    [self.weakNetworkStateDelegate didGoOffline];

}

@end



@implementation ZMTransportSession (URLSessionDelegate)

- (void)URLSession:(ZMURLSession *)URLSession dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler;
{
    NOT_USED(URLSession);
    NOT_USED(dataTask);
    // Forward the response to the request scheduler:
    NSHTTPURLResponse * const HTTPResponse = (id) response;
    [self.requestScheduler processCompletedURLResponse:HTTPResponse URLError:nil];
    // Continue the task:
    completionHandler(NSURLSessionResponseAllow);
    
    [self updateNetworkStatusFromDidReadDataFromNetwork];
}

- (void)URLSessionDidReceiveData:(ZMURLSession *)URLSession;
{
    NOT_USED(URLSession);
    [self updateNetworkStatusFromDidReadDataFromNetwork];
}

- (void)URLSession:(ZMURLSession *)URLSession taskDidComplete:(NSURLSessionTask *)task transportRequest:(ZMTransportRequest *)request responseData:(NSData *)data;
{
    NSTimeInterval timeDiff = -[request.startOfUploadTimestamp timeIntervalSinceNow];
    ZMLogDebug(@"(Almost) bare network time for request %p %@ %@: %@s", request, request.methodAsString, request.path, @(timeDiff));
    NSError *error = task.error;
    NSHTTPURLResponse *HTTPResponse = (id)task.response;
    [self processCookieResponse:HTTPResponse];

    BOOL didConsume = [self.accessTokenHandler consumeRequestWithTask:task data:data session:URLSession shouldRetry:self.requestScheduler.canSendRequests];
    if (!didConsume) {
        [self didCompleteRequest:request data:data task:task error:error];
    }
    
    [self.requestScheduler processCompletedURLTask:task];
    [self.expiredTasks removeObject:task];
}

@end



@implementation ZMTransportSession (ReachabilityObserver)

- (void)reachabilityDidChange:(ZMReachability *)reachability;
{
    ZMTraceTransportSessionReachability(1, reachability.mayBeReachable);
    ZMLogInfo(@"reachabilityDidChange -> mayBeReachable = %@", reachability.mayBeReachable ? @"YES" : @"NO");
    [self.requestScheduler reachabilityDidChange:reachability];
    [self.pushChannel reachabilityDidChange:reachability];

    id<ZMNetworkStateDelegate> networkStateDelegate = self.weakNetworkStateDelegate;
    if(self.reachability.mayBeReachable) {
        [networkStateDelegate didReceiveData];
    } else {
        [networkStateDelegate didGoOffline];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:ZMTransportSessionReachabilityChangedNotificationName object:nil];
}

- (void)updateNetworkStatusFromDidReadDataFromNetwork;
{
    [self.weakNetworkStateDelegate didReceiveData];
}

@end




@implementation ZMTransportSession (PushChannel)

- (void)openPushChannelWithConsumer:(id<ZMPushChannelConsumer>)consumer groupQueue:(id<ZMSGroupQueue>)groupQueue;
{
    [self.pushChannel setPushChannelConsumer:consumer groupQueue:groupQueue];
}

- (void)closePushChannelAndRemoveConsumer;
{
    [self.pushChannel closeAndRemoveConsumer];
}

- (void)restartPushChannel
{
    [self.pushChannel close];
    [self.pushChannel scheduleOpenPushChannel];
}

@end

@implementation ZMTransportSession (Testing)

- (void)setAccessToken:(ZMAccessToken *)accessToken;
{
    [self.accessTokenHandler setAccessTokenForTesting:accessToken];
}

@end


@implementation ZMTransportEnqueueResult

+ (instancetype)resultDidHaveLessRequestsThanMax:(BOOL)didHaveLessThanMax didGenerateNonNullRequest:(BOOL) didGenerateRequest;
{
    ZMTransportEnqueueResult *result = [[ZMTransportEnqueueResult alloc] init];
    if (result != nil) {
        result->_didGenerateNonNullRequest = didGenerateRequest;
        result->_didHaveLessRequestThanMax = didHaveLessThanMax;
    }
    return result;
}

@end





@implementation ZMOpenPushChannelRequest

- (BOOL)isEqual:(id)object;
{
    return [object isKindOfClass:[ZMOpenPushChannelRequest class]];
}

- (ZMTransportRequest *)transportRequest;
{
    return nil;
}

- (BOOL)isPushChannelRequest;
{
    return YES;
}

- (BOOL)needsAuthentication;
{
    return YES;
}

@end



@implementation ZMTransportRequest (Scheduler)

- (ZMTransportRequest *)transportRequest;
{
    return self;
}

- (BOOL)isPushChannelRequest;
{
    return NO;
}

@end



@implementation ZMTransportSession (ApplicationStates)


- (BOOL)isActive;
{
    return !self.applicationIsBackgrounded || self.shouldKeepWebsocketOpen;
}

- (void)updateActivity;
{
    if (self.isActive) {
        [self didBecomeActive];
    } else {
        [self didBecomeInactive];
    }
}

- (void)didBecomeActive;
{
    [self.pushChannel scheduleOpenPushChannel];
    [self.requestScheduler applicationWillEnterForeground];
}

- (void)didBecomeInactive;
{
    [self.pushChannel close];
}

@end
//
//  RNFetchBlobNetwork.m
//  RNFetchBlob
//
//  Created by wkh237 on 2016/6/6.
//  Copyright © 2016 wkh237. All rights reserved.
//


#import <Foundation/Foundation.h>
#import "RNFetchBlobNetwork.h"

#import "RNFetchBlob.h"
#import "RNFetchBlobConst.h"
#import "RNFetchBlobProgress.h"
#if __has_include(<React/RCTAssert.h>)
#import <React/RCTRootView.h>
#import <React/RCTLog.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTBridge.h>
#else
#import "RCTRootView.h"
#import "RCTLog.h"
#import "RCTEventDispatcher.h"
#import "RCTBridge.h"
#endif

////////////////////////////////////////
//
//  HTTP request handler
//
////////////////////////////////////////

NSMapTable * expirationTable;

__attribute__((constructor))
static void initialize_tables() {
    if (expirationTable == nil) {
        expirationTable = [[NSMapTable alloc] init];
    }
}


typedef NS_ENUM(NSUInteger, ResponseFormat) {
    UTF8,
    BASE64,
    AUTO
};


@interface RNFetchBlobNetwork ()
{
    BOOL * respFile;
    BOOL isNewPart;
    BOOL * isIncrement;
    NSMutableData * partBuffer;
    NSString * destPath;
    NSOutputStream * writeStream;
    long bodyLength;
    NSMutableDictionary * respInfo;
    NSInteger respStatus;
    NSMutableArray * redirects;
    ResponseFormat responseFormat;
    BOOL * followRedirect;
    BOOL backgroundTask;
    BOOL uploadTask;
    BOOL downloadTask;
}

@end

@implementation RNFetchBlobNetwork


- (id)init {
    self = [super init];
    if (self) {
        self.requestsTable = [NSMapTable mapTableWithKeyOptions:NSMapTableStrongMemory valueOptions:NSMapTableWeakMemory];

        self.taskQueue = [[NSOperationQueue alloc] init];
        self.taskQueue.qualityOfService = NSQualityOfServiceUtility;
        self.taskQueue.maxConcurrentOperationCount = 10;
        self.rebindProgressDict = [NSMutableDictionary dictionary];
        self.rebindUploadProgressDict = [NSMutableDictionary dictionary];
    }

    return self;
}

+ (RNFetchBlobNetwork* _Nullable)sharedInstance {
    static id _sharedInstance = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        _sharedInstance = [[self alloc] init];
    });

    return _sharedInstance;
}

- (void) sendRequest:(__weak NSDictionary  * _Nullable )options
       contentLength:(long) contentLength
              bridge:(RCTBridge * _Nullable)bridgeRef
              taskId:(NSString * _Nullable)taskId
         withRequest:(__weak NSURLRequest * _Nullable)req
            callback:(_Nullable RCTResponseSenderBlock) callback
{
    RNFetchBlobRequest *request = [[RNFetchBlobRequest alloc] init];
    [request sendRequest:options
           contentLength:contentLength
                  bridge:bridgeRef
                  taskId:taskId
             withRequest:req
      taskOperationQueue:self.taskQueue
                callback:callback];

    @synchronized([RNFetchBlobNetwork class]) {
        [self.requestsTable setObject:request forKey:taskId];
        [self checkProgressConfig];
    }

    backgroundTask = [options valueForKey:@"IOSBackgroundTask"] == nil ? NO : [[options valueForKey:@"IOSBackgroundTask"] boolValue];
    downloadTask = [options valueForKey:@"IOSDownloadTask"] == nil ? NO : [[options valueForKey:@"IOSDownloadTask"] boolValue];
    uploadTask = [options valueForKey:@"IOSUploadTask"] == nil ? NO : [[options valueForKey:@"IOSUploadTask"] boolValue];

    NSString * filepath = [options valueForKey:@"uploadFilePath"];

    followRedirect = [options valueForKey:@"followRedirect"] == nil ? YES : [[options valueForKey:@"followRedirect"] boolValue];
    isIncrement = [options valueForKey:@"increment"] == nil ? NO : [[options valueForKey:@"increment"] boolValue];
    redirects = [[NSMutableArray alloc] init];

    if(req.URL != nil)
        [redirects addObject:req.URL.absoluteString];

    // set response format
    NSString * rnfbResp = [req.allHTTPHeaderFields valueForKey:@"RNFB-Response"];
    if([[rnfbResp lowercaseString] isEqualToString:@"base64"])
        responseFormat = BASE64;
    else if([[rnfbResp lowercaseString] isEqualToString:@"utf8"])
        responseFormat = UTF8;
    else
        responseFormat = AUTO;

    NSString * path = [self.options valueForKey:CONFIG_FILE_PATH];
    NSString * ext = [self.options valueForKey:CONFIG_FILE_EXT];
	NSString * key = [self.options valueForKey:CONFIG_KEY];
    // __block NSURLSession * session;

    bodyLength = contentLength;

    // the session trust any SSL certification
    NSURLSessionConfiguration *defaultConfigObject;

    defaultConfigObject = [NSURLSessionConfiguration defaultSessionConfiguration];

    if(backgroundTask)
    {
        defaultConfigObject = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:taskId];
    }

    // set request timeout
    float timeout = [options valueForKey:@"timeout"] == nil ? -1 : [[options valueForKey:@"timeout"] floatValue];
    if(timeout > 0)
    {
        defaultConfigObject.timeoutIntervalForRequest = timeout/1000;
    }
    defaultConfigObject.HTTPMaximumConnectionsPerHost = 10;

    _session = [NSURLSession sessionWithConfiguration:defaultConfigObject delegate:self delegateQueue:taskQueue];

    if(path != nil || [self.options valueForKey:CONFIG_USE_TEMP]!= nil)
    {
        respFile = YES;

		NSString* cacheKey = taskId;
		if (key != nil) {
            cacheKey = [self md5:key];
			if (cacheKey == nil) {
				cacheKey = taskId;
			}

			destPath = [RNFetchBlobFS getTempPath:cacheKey withExtension:[self.options valueForKey:CONFIG_FILE_EXT]];
            if ([[NSFileManager defaultManager] fileExistsAtPath:destPath]) {
				callback(@[[NSNull null], RESP_TYPE_PATH, destPath]);
                return;
            }
		}

        if(path != nil)
            destPath = path;
        else
            destPath = [RNFetchBlobFS getTempPath:cacheKey withExtension:[self.options valueForKey:CONFIG_FILE_EXT]];
    }
    else
    {
        respData = [[NSMutableData alloc] init];
        respFile = NO;
    }


    if(uploadTask)
    {
        __block NSURLSessionUploadTask * task = [_session uploadTaskWithRequest:req fromFile:[NSURL URLWithString:filepath]];
        [taskTable setObject:task forKey:taskId];
        [task resume];
    }
    else if(downloadTask)
    {
        __block NSURLSessionDownloadTask * task = [_session downloadTaskWithRequest:req];
        [taskTable setObject:task forKey:taskId];
        [task resume];
    }
    else
    {
        __block NSURLSessionDataTask * task = [_session dataTaskWithRequest:req];
        [taskTable setObject:task forKey:taskId];
        [task resume];
    }

    // network status indicator
    if([[options objectForKey:CONFIG_INDICATOR] boolValue] == YES)
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
    __block UIApplication * app = [UIApplication sharedApplication];
}

- (void) checkProgressConfig {
    //reconfig progress
    [self.rebindProgressDict enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, RNFetchBlobProgress * _Nonnull config, BOOL * _Nonnull stop) {
        [self enableProgressReport:key config:config];
    }];
    [self.rebindProgressDict removeAllObjects];

    //reconfig uploadProgress
    [self.rebindUploadProgressDict enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, RNFetchBlobProgress * _Nonnull config, BOOL * _Nonnull stop) {
        [self enableUploadProgress:key config:config];
    }];
    [self.rebindUploadProgressDict removeAllObjects];
}

- (void) enableProgressReport:(NSString *) taskId config:(RNFetchBlobProgress *)config
////////////////////////////////////////
//
//  NSURLSession delegates
//
////////////////////////////////////////


#pragma mark NSURLSession delegate methods


#pragma mark - Received Response

// set expected content length on response received
- (void) URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
    if (config) {
        @synchronized ([RNFetchBlobNetwork class]) {
            if (![self.requestsTable objectForKey:taskId]) {
                [self.rebindProgressDict setValue:config forKey:taskId];
            } else {
                [self.requestsTable objectForKey:taskId].progressConfig = config;
            }
        }
        else
            respType = @"text";
            respInfo = @{
                        @"taskId": taskId,
                        @"state": @"2",
                        @"headers": headers,
                        @"redirects": redirects,
                        @"respType" : respType,
                        @"timeout" : @NO,
                        @"status": [NSNumber numberWithInteger:statusCode]
                        };

            #pragma mark - handling cookies
            // # 153 get cookies
            if(response.URL != nil)
            {
                NSHTTPCookieStorage * cookieStore = [NSHTTPCookieStorage sharedHTTPCookieStorage];
                NSArray<NSHTTPCookie *> * cookies = [NSHTTPCookie cookiesWithResponseHeaderFields: headers forURL:response.URL];
                if(cookies != nil && [cookies count] > 0) {
                    [cookieStore setCookies:cookies forURL:response.URL mainDocumentURL:nil];
                }
            }

            [self.bridge.eventDispatcher
            sendDeviceEventWithName: EVENT_STATE_CHANGE
            body:respInfo
            ];
            headers = nil;
            respInfo = nil;

    }
    else
        NSLog(@"oops");

    completionHandler(NSURLSessionResponseAllow);
}



// data download progress handler
- (void) URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data
{
    // For #143 handling multipart/x-mixed-replace response
    if(self.isServerPush)
    {
        [partBuffer appendData:data];
        return ;
    }

    if(respFile == NO)
    {
        NSNumber * received = [NSNumber numberWithLong:[data length]];
        receivedBytes += [received longValue];
        NSString * chunkString = @"";

        if(isIncrement == YES)
        {
            chunkString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        }

        [respData appendData:data];

        RNFetchBlobProgress * pconfig = [progressTable valueForKey:taskId];
        if(expectedBytes == 0)
            return;
        NSNumber * now =[NSNumber numberWithFloat:((float)receivedBytes/(float)expectedBytes)];
        RCTLog(@"check the didReceiveData ----%f %f %@",(float)receivedBytes,(float)expectedBytes,taskId);
        if(pconfig != nil && [pconfig shouldReport:now])
        {
            [self.bridge.eventDispatcher
             sendDeviceEventWithName:EVENT_PROGRESS
             body:@{
                    @"taskId": taskId,
                    @"written": [NSString stringWithFormat:@"%d", receivedBytes],
                    @"total": [NSString stringWithFormat:@"%d", expectedBytes],
                    @"chunk": chunkString
                    }
             ];
        }
        received = nil;
    }
}
#pragma mark -
#pragma mark NSURLSessionDownloadTask delegate methods
#pragma mark -

  #pragma mark - download progress handler

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {

        RNFetchBlobProgress * pconfig = [progressTable valueForKey:taskId];
        if(totalBytesWritten == 0)
            return;
        NSNumber * now =[NSNumber numberWithFloat:((double)bytesWritten/(double)totalBytesWritten)];
        RCTLog(@"check the now ----%f %f %@",(double)bytesWritten,(double)totalBytesWritten,taskId);
        if(pconfig != nil && [pconfig shouldReport:now])
        {
            [self.bridge.eventDispatcher
             sendDeviceEventWithName:EVENT_PROGRESS
             body:@{
                    @"taskId": taskId,
                    @"written": [NSString stringWithFormat:@"%d", totalBytesWritten],
                    @"total": [NSString stringWithFormat:@"%d", totalBytesExpectedToWrite]
                    }
             ];
        }
}

 #pragma mark - handling didFinishDownloadingToURL

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    @try{
        NSLog(@"file path : %@", destPath);
        if ([[NSFileManager defaultManager] fileExistsAtPath:destPath]) {
            //Remove the old file from directory
            [[NSFileManager defaultManager] removeItemAtPath:destPath error:NULL];

        }
        NSError *error;
        NSURL *documentURL = [NSURL fileURLWithPath:destPath];

        [[NSFileManager defaultManager] moveItemAtURL:location
                                                toURL:documentURL
                                                error:&error];
        if (!error){
            //Handle error here
        }
    }
    @catch(NSException * ex)
    {
        NSLog(@"write file error");
    }
}

- (void) enableUploadProgress:(NSString *) taskId config:(RNFetchBlobProgress *)config

# pragma mark - Complete and Error callback
- (void) URLSession:(NSURLSession *)session didBecomeInvalidWithError:(nullable NSError *)error
{
    if (config) {
        @synchronized ([RNFetchBlobNetwork class]) {
            if (![self.requestsTable objectForKey:taskId]) {
                [self.rebindUploadProgressDict setValue:config forKey:taskId];
            } else {
                [self.requestsTable objectForKey:taskId].uploadProgressConfig = config;
            }
        }
    }
}

- (void) cancelRequest:(NSString *)taskId
{
    NSURLSessionDataTask * task;

    @synchronized ([RNFetchBlobNetwork class]) {
        task = [self.requestsTable objectForKey:taskId].task;
    }

    if (task && task.state == NSURLSessionTaskStateRunning) {
        [task cancel];
    }
}

// removing case from headers
+ (NSMutableDictionary *) normalizeHeaders:(NSDictionary *)headers
{
    NSMutableDictionary * mheaders = [[NSMutableDictionary alloc]init];
    for (NSString * key in headers) {
        [mheaders setValue:[headers valueForKey:key] forKey:[key lowercaseString]];
    }

    return mheaders;
}

// #115 Invoke fetch.expire event on those expired requests so that the expired event can be handled
+ (void) emitExpiredTasks
}




   #pragma mark - Authentication methods

- (void) URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable credantial))completionHandler
{
    BOOL trusty = [options valueForKey:CONFIG_TRUSTY];
    if(!trusty)
    {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
    }
    else
    {
        completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
    }
}

- (void) URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler
{
    @synchronized ([RNFetchBlobNetwork class]){
        NSEnumerator * emu =  [expirationTable keyEnumerator];
        NSString * key;

        while ((key = [emu nextObject]))
        {
            RCTBridge * bridge = [RNFetchBlob getRCTBridge];
            id args = @{ @"taskId": key };
            [bridge.eventDispatcher sendDeviceEventWithName:EVENT_EXPIRE body:args];

        }

        // clear expired task entries
        [expirationTable removeAllObjects];
        expirationTable = [[NSMapTable alloc] init];
    }
}


@end

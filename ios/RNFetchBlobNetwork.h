//
//  RNFetchBlobNetwork.h
//  RNFetchBlob
//
//  Created by wkh237 on 2016/6/6.
//  Copyright © 2016 wkh237. All rights reserved.
//

#ifndef RNFetchBlobNetwork_h
#define RNFetchBlobNetwork_h

#import <Foundation/Foundation.h>
#import "RNFetchBlobProgress.h"
#import "RNFetchBlobFS.h"
#import "RNFetchBlobRequest.h"

#if __has_include(<React/RCTAssert.h>)
#import <React/RCTBridgeModule.h>
#else
#import "RCTBridgeModule.h"
#endif


@interface RNFetchBlobNetwork : NSObject  <NSURLSessionDelegate, NSURLSessionTaskDelegate, NSURLSessionDataDelegate>

@property(nonnull, nonatomic) NSOperationQueue *taskQueue;
@property(nonnull, nonatomic) NSMapTable<NSString*, RNFetchBlobRequest*> * requestsTable;
@property(nonnull, nonatomic) NSMutableDictionary<NSString*, RNFetchBlobProgress*> *rebindProgressDict;
@property(nonnull, nonatomic) NSMutableDictionary<NSString*, RNFetchBlobProgress*> *rebindUploadProgressDict;
@property (nullable, nonatomic) NSString * taskId;
@property (nonatomic) int expectedBytes;
@property (nonatomic) int receivedBytes;
@property (nonatomic) BOOL isServerPush;
@property (nullable, nonatomic) NSMutableData * respData;
@property (strong, nonatomic) RCTResponseSenderBlock callback;
@property (nullable, nonatomic) RCTBridge * bridge;
@property (nullable, nonatomic) NSDictionary * options;
@property (nullable, nonatomic) RNFetchBlobFS * fileStream;
@property (strong, nonatomic) CompletionHander fileTaskCompletionHandler;
@property (strong, nonatomic) DataTaskCompletionHander dataTaskCompletionHandler;

@property (nullable, nonatomic) NSError * error;
@property (nonatomic, strong) __block NSURLSession * session;

+ (RNFetchBlobNetwork* _Nullable)sharedInstance;
+ (NSMutableDictionary  * _Nullable ) normalizeHeaders:(NSDictionary * _Nullable)headers;
+ (void) emitExpiredTasks;

- (nullable id) init;
- (void) sendRequest:(NSDictionary  * _Nullable )options
       contentLength:(long)contentLength
              bridge:(RCTBridge * _Nullable)bridgeRef
              taskId:(NSString * _Nullable)taskId
         withRequest:(NSURLRequest * _Nullable)req
            callback:(_Nullable RCTResponseSenderBlock) callback;
- (void) cancelRequest:(NSString * _Nonnull)taskId;
- (void) enableProgressReport:(NSString * _Nonnull) taskId config:(RNFetchBlobProgress * _Nullable)config;
- (void) enableUploadProgress:(NSString * _Nonnull) taskId config:(RNFetchBlobProgress * _Nullable)config;


@end


#endif /* RNFetchBlobNetwork_h */

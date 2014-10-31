
#import "DDCometLongPollingTransport.h"
#import "DDCometClient.h"
#import "DDCometMessage.h"
#import "DDQueue.h"


@interface DDCometLongPollingTransport ()

- (NSURLConnection *)sendMessages:(NSArray *)messages;
- (NSArray *)outgoingMessages;
- (NSURLRequest *)requestWithMessages:(NSArray *)messages;
- (id)keyWithConnection:(NSURLConnection *)connection;

@property (nonatomic, retain) NSArray *cookies;
@property (nonatomic, retain) NSTimer *pollTimer;

@end

@implementation DDCometLongPollingTransport

- (id)initWithClient:(DDCometClient *)client
{
	if ((self = [super init]))
	{
		m_client = [client retain];
		m_responseDatas = [[NSMutableDictionary alloc] initWithCapacity:2];
		self.cookies = client.cookies;
	}
	return self;
}

- (void)dealloc
{
	self.cookies = nil;
	[m_responseDatas release];
	[m_client release];
	[super dealloc];
}

- (void)start
{
	self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(longPollTimerFired:) userInfo:nil repeats:YES];
}

- (void)cancel
{
	[self.pollTimer invalidate];
	self.pollTimer = nil;
	m_shouldCancel = YES;
}

#pragma mark -

- (void)longPollTimerFired:(NSTimer *)timer
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSArray *messages = [self outgoingMessages];
    
    BOOL isPolling = NO;
    if ([messages count] == 0)
    {
        if (m_client.state == DDCometStateConnected)
        {
            isPolling = YES;
            DDCometMessage *message = [DDCometMessage messageWithChannel:@"/meta/connect"];
            message.clientID = m_client.clientID;
            message.connectionType = @"long-polling";
            assert(message.clientID);
            messages = [NSArray arrayWithObject:message];
        }
        else
        {
            [NSThread sleepForTimeInterval:0.5];
        }
    }
    
    NSURLConnection *connection = [self sendMessages:messages];
    if (connection)
    {
        if (isPolling)
        {
            if (m_shouldCancel)
            {
                m_shouldCancel = NO;
                [connection cancel];
            }
            else
            {
                messages = [self outgoingMessages];
                [self sendMessages:messages];
            }
        }
    }
    
    [pool release];
}

- (NSURLConnection *)sendMessages:(NSArray *)messages
{
    NSURLConnection *connection = nil;
    if ([messages count] != 0)
    {
        NSURLRequest *request = [self requestWithMessages:messages];
        connection = [NSURLConnection connectionWithRequest:request delegate:self];
        [connection start];
    }

	return connection;
}

- (NSArray *)outgoingMessages
{
	NSMutableArray *messages = [NSMutableArray array];
	DDCometMessage *message;
	id<DDQueue> outgoingQueue = [m_client outgoingQueue];
	while ((message = [outgoingQueue removeObject]))
		[messages addObject:message];
	return messages;
}

- (NSURLRequest *)requestWithMessages:(NSArray *)messages
{
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:m_client.endpointURL];

    NSMutableArray *finalMessages = [NSMutableArray array];
    for(DDCometMessage *message in messages)
        [finalMessages addObject:[message proxyForJson]];

    NSData *body = [NSJSONSerialization dataWithJSONObject:finalMessages options:0 error:nil];

	if(self.cookies)
		[request setAllHTTPHeaderFields:[NSHTTPCookie requestHeaderFieldsWithCookies:self.cookies]];
    
	[request setHTTPMethod:@"POST"];
	[request setValue:@"application/json;charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
    
	[request setHTTPBody:body];
	
	NSNumber *timeout = [m_client.advice objectForKey:@"timeout"];
	if (timeout)
		[request setTimeoutInterval:([timeout floatValue] / 1000)];
	
	return request;
}

- (id)keyWithConnection:(NSURLConnection *)connection
{
	return [NSNumber numberWithUnsignedInteger:[connection hash]];
}

#pragma mark - NSURLConnectionDelegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
	[m_responseDatas setObject:[NSMutableData data] forKey:[self keyWithConnection:connection]];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
	NSMutableData *responseData = [m_responseDatas objectForKey:[self keyWithConnection:connection]];
	[responseData appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
	NSData *responseData = [[m_responseDatas objectForKey:[self keyWithConnection:connection]] retain];
	[m_responseDatas removeObjectForKey:[self keyWithConnection:connection]];
	
	NSArray *responses = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil];

	[responseData release];
	responseData = nil;
	
	id<DDQueue> incomingQueue = [m_client incomingQueue];
	
	for (NSDictionary *messageData in responses)
	{
		DDCometMessage *message = [DDCometMessage messageWithJson:messageData];
		[incomingQueue addObject:message];
	}
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
	[m_responseDatas removeObjectForKey:[self keyWithConnection:connection]];
}

@end

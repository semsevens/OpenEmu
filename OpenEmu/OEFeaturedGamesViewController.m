/*
 Copyright (c) 2014, OpenEmu Team
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "OEFeaturedGamesViewController.h"

#import "OETheme.h"
#import "OEDownload.h"
#import "OEBlankSlateBackgroundView.h"
#import "OEFeaturedGamesCoverView.h"
#import "OEDBSystem.h"
#import "OELibraryController.h"

#import "OEFeaturedGamesBlankSlateView.h"

#import "NSArray+OEAdditions.h"
#import "NS(Attributed)String+Geometrics.h"

NSString * const OEFeaturedGamesURLString = @"https://raw.githubusercontent.com/OpenEmu/OpenEmu-Update/master/games.xml";

NSString * const OELastFeaturedGamesCheckKey = @"lastFeaturedGamesCheck";

const static CGFloat DescriptionX     = 146.0;
const static CGFloat TableViewSpacing = 86.0;

@interface OEFeaturedGame : NSObject
- (instancetype)initWithNode:(NSXMLNode*)node;

@property (readonly, copy) NSString *name;
@property (readonly, copy) NSString *developer;
@property (readonly, copy) NSString *website;
@property (readonly, copy) NSString *fileURLString;
@property (readonly, copy) NSString *gameDescription;
@property (readonly, copy) NSDate   *added;
@property (readonly, copy) NSDate   *released;
@property (readonly)       NSInteger fileIndex;
@property (readonly, copy) NSArray  *images;
@property (readonly, copy) NSString  *md5;

@property (nonatomic, readonly) NSString *systemShortName;

@property (readonly, copy) NSString *systemIdentifier;
@end
@interface OEFeaturedGamesViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (strong) NSArray *games;
@property (strong) OEDownload *currentDownload;
@property (strong, nonatomic) OEFeaturedGamesBlankSlateView *blankSlate;
@end

@implementation OEFeaturedGamesViewController
@synthesize blankSlate=_blankSlate;

+ (void)initialize
{
    if(self == [OEFeaturedGamesViewController class])
    {
        NSDictionary *defaults = @{ OELastFeaturedGamesCheckKey:[NSDate dateWithTimeIntervalSince1970:0],
                                    };
        [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
    }
}

- (NSString*)nibName
{
    return @"OEFeaturedGamesViewController";
}

- (void)loadView
{
    [super loadView];

    NSView *view = self.view;

    [view setAutoresizingMask:NSViewWidthSizable|NSViewHeightSizable];

    NSTableView *tableView = [self tableView];
    [tableView setAllowsColumnReordering:NO];
    [tableView setAllowsEmptySelection:YES];
    [tableView setAllowsMultipleSelection:NO];
    [tableView setAllowsColumnResizing:NO];
    [tableView setAllowsTypeSelect:NO];
    [tableView setDelegate:self];
    [tableView setDataSource:self];
    [tableView sizeLastColumnToFit];
    [tableView setColumnAutoresizingStyle:NSTableViewUniformColumnAutoresizingStyle];
    [[[tableView tableColumns] lastObject] setResizingMask:NSTableColumnAutoresizingMask];

    [tableView setPostsBoundsChangedNotifications:YES];
    [tableView setPostsFrameChangedNotifications:YES];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(tableViewFrameDidChange:) name:NSViewFrameDidChangeNotification object:tableView];
}

- (void)viewDidAppear
{
    [super viewDidAppear];
    // Fetch games if we haven't already, this allows reloading if an error occured, by switching to a different collection or media view and then back to featured games
    if([[self games] count] == 0)
    {
        [self updateGames];
    }
}
#pragma mark - Data Handling
- (void)updateGames
{
    // Indicate that we're fetching some remote resources
    [self displayUpdate];

    // Cancel last download
    [[self currentDownload] cancelDownload];

    NSURL *url = [NSURL URLWithString:OEFeaturedGamesURLString];

    OEDownload *download = [[OEDownload alloc] initWithURL:url];
    OEDownload __weak *blockDL = download;
    [download setCompletionHandler:^(NSURL *destination, NSError *error) {
        if([self currentDownload]==blockDL)
            [self setCurrentDownload:nil];

        if(error == nil && destination != nil)
        {
            if(![self parseFileAtURL:destination error:&error])
            {
                [self displayError:error];
            }
            else
            {
                [self displayResults];
            }
        }
        else
        {
            [self displayError:error];
        }
    }];
    [self setCurrentDownload:download];
    [download startDownload];
}

- (BOOL)parseFileAtURL:(NSURL*)url error:(NSError**)outError
{
    NSError       *error    = nil;
    NSXMLDocument *document = [[NSXMLDocument alloc] initWithContentsOfURL:url options:0 error:&error];
    if(document == nil)
    {
        DLog(@"%@", error);
        return NO;
    }

    NSArray *dates = [document nodesForXPath:@"//game/@added" error:&error];
    dates = [dates arrayByEvaluatingBlock:^id(id obj, NSUInteger idx, BOOL *stop) {
        return [NSDate dateWithTimeIntervalSince1970:[[obj stringValue] integerValue]];
    }];

    NSDate *lastCheck = [[NSUserDefaults standardUserDefaults] objectForKey:OELastFeaturedGamesCheckKey];
    NSMutableIndexSet *newGameIndices = [NSMutableIndexSet indexSet];
    [dates enumerateObjectsUsingBlock:^(NSDate *obj, NSUInteger idx, BOOL *stop) {
        if([obj compare:lastCheck] == NSOrderedDescending)
            [newGameIndices addIndex:idx];
    }];

    NSArray *allGames = [document nodesForXPath:@"//game" error:&error];
    NSArray *newGames = [allGames objectsAtIndexes:newGameIndices];

    self.games = [newGames arrayByEvaluatingBlock:^id(id node, NSUInteger idx, BOOL *block) {
        return [[OEFeaturedGame alloc] initWithNode:node];
    }];

    return YES;
}

#pragma mark - View Management
- (void)displayUpdate
{
    OEFeaturedGamesBlankSlateView *blankSlate = [[OEFeaturedGamesBlankSlateView alloc] initWithFrame:[[self view] bounds]];
    [blankSlate setProgressAction:@"Fetching Games…"];
    [self showBlankSlate:blankSlate];

    [[self tableView] setHidden:YES];

}

- (void)displayError:(NSError*)error
{
    NSLog(@"We have an error…");
    OEFeaturedGamesBlankSlateView *blankSlate = [[OEFeaturedGamesBlankSlateView alloc] initWithFrame:[[self view] bounds]];
    [blankSlate setError:@"No Internet Connection"];
    [self showBlankSlate:blankSlate];
}

- (void)displayResults
{
    NSLog(@"We have results!");

    [_blankSlate removeFromSuperview];
    [self setBlankSlate:nil];

    [[self tableView] reloadData];
    [[self tableView] setHidden:NO];
}

- (NSDictionary*)descriptionStringAttributes
{
    OEThemeTextAttributes *attribtues = [[OETheme sharedTheme] themeTextAttributesForKey:@"homebrew_description"];
    return [attribtues textAttributesForState:OEThemeStateDefault];
}

- (void)tableViewFrameDidChange:(NSNotification*)notification
{
    [[self tableView] beginUpdates];
    [[self tableView] reloadData];
    [[self tableView] endUpdates];
}

#pragma mark -
- (void)showBlankSlate:(OEFeaturedGamesBlankSlateView *)blankSlate
{
    if(_blankSlate != blankSlate)
    {
        [_blankSlate removeFromSuperview];
    }

    [self setBlankSlate:blankSlate];

    if(_blankSlate)
    {
        NSView *view = [self view];
        NSRect bounds = [view bounds];
        NSLog(@"showBlankSlate: %@", NSStringFromRect(bounds));
        [_blankSlate setFrame:bounds];

        [view addSubview:_blankSlate];
        [_blankSlate setAutoresizingMask:NSViewHeightSizable|NSViewWidthSizable];
    }
}
#pragma mark - UI Methods
- (IBAction)gotoDeveloperWebsite:(id)sender
{
    NSInteger row = [self rowOfView:sender];

    if(row < 0 || row >= [[self games] count]) return;

    OEFeaturedGame *game = [[self games] objectAtIndex:row];

    NSURL *url = [NSURL URLWithString:[game website]];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

- (IBAction)importGame:(id)sender
{
    NSInteger row = [self rowOfView:sender];

    if(row < 0 || row >= [[self games] count]) return;

    OEFeaturedGame *game = [[self games] objectAtIndex:row];
    NSURL *url = [NSURL URLWithString:[game fileURLString]];
    NSInteger fileIndex = [game fileIndex];

    NSLog(@"%@ %ld", url, fileIndex);
}

- (IBAction)launchGame:(id)sender
{
    NSInteger row = [self rowOfView:sender];

    if(row < 0 || row >= [[self games] count]) return;

    OEFeaturedGame *featuredGame = [[self games] objectAtIndex:row];
    NSURL *url = [NSURL URLWithString:[featuredGame fileURLString]];
    NSInteger fileIndex = [featuredGame fileIndex];
    NSString *systemIdentifier = [featuredGame systemIdentifier];
    NSString *md5  = [featuredGame md5];
    NSString *name = [featuredGame name];

    OELibraryDatabase      *db = [[self libraryController] database];
    NSManagedObjectContext *context = [db mainThreadContext];
    OEDBRom *rom = [OEDBRom romWithMD5HashString:md5 inContext:context error:nil];
    if(rom == nil)
    {
        NSEntityDescription *romDescription  = [OEDBRom entityDescriptionInContext:context];
        NSEntityDescription *gameDescription = [OEDBGame entityDescriptionInContext:context];
        rom = [[OEDBRom alloc] initWithEntity:romDescription insertIntoManagedObjectContext:context];
        [rom setSourceURL:url];
        [rom setArchiveFileIndex:@(fileIndex)];
        [rom setMd5:[md5 lowercaseString]];

        OEDBGame *game = [[OEDBGame alloc] initWithEntity:gameDescription insertIntoManagedObjectContext:context];
        [game setRoms:[NSSet setWithObject:rom]];
        [game setName:name];

        [game setBoxImageByURL:[[featuredGame images] objectAtIndex:0]];

        OEDBSystem *system = [OEDBSystem systemForPluginIdentifier:systemIdentifier inContext:context];
        [game setSystem:system];
    }

    OEDBGame *game = [rom game];
    [game save];
    [[self libraryController] startGame:game];
}

- (NSInteger)rowOfView:(NSView*)view
{
    NSRect viewRect = [view frame];
    NSRect viewRectOnView = [[self tableView] convertRect:viewRect fromView:[view superview]];

    NSInteger row = [[self tableView] rowAtPoint:(NSPoint){NSMidX(viewRectOnView), NSMidY(viewRectOnView)}];

    if(row == 1)
    {
        NSView *container = [[view superview] superview];
        return [[container subviews] indexOfObjectIdenticalTo:[view superview]];
    }

    return row;
}
#pragma mark - Table View Datasource
- (NSInteger)numberOfRowsInTableView:(IKImageBrowserView *)aBrowser
{
    return [[self games] count] +0; // -3 for featured games which share a row + 2 for headers +1 for the shared row
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex
{
    if(rowIndex == 0) return OELocalizedString(@"Featured Games", @"");
    if(rowIndex == 2) return OELocalizedString(@"All Homebrew", @"");

    if(rowIndex == 1) return [[self games] subarrayWithRange:NSMakeRange(0, 3)];

    return [[self games] objectAtIndex:rowIndex];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    NSTableCellView *view = nil;
    
    if(row == 0 || row == 2)
    {
        view = [tableView makeViewWithIdentifier:@"HeaderView" owner:self];
    }
    else if(row == 1)
    {
        view = [tableView makeViewWithIdentifier:@"FeatureView" owner:self];
        NSArray *games = [self tableView:tableView objectValueForTableColumn:tableColumn row:row];

        NSView *subview = [[view subviews] lastObject];
        [games enumerateObjectsUsingBlock:^(OEFeaturedGame *game, NSUInteger idx, BOOL *stop) {
            NSView *container = [[subview subviews] objectAtIndex:idx];

            OEFeaturedGamesCoverView *artworkView = [[container subviews] objectAtIndex:0];
            [artworkView setURLs:[game images]];
            [artworkView setTarget:self];
            [artworkView setDoubleAction:@selector(launchGame:)];

            NSTextField *label = [[container subviews] objectAtIndex:1];
            [label setStringValue:[game name]];

            // setup '<developer>'
            NSButton *developer = [[container subviews] objectAtIndex:4];
            [developer setTitle:[game developer]];
            [developer setTarget:self];
            [developer setAction:@selector(gotoDeveloperWebsite:)];
            [developer setObjectValue:[game website]];
            [developer sizeToFit];
            // size to fit ignores shadow… so we manually adjust height
            NSSize size = [developer frame].size;
            size.height += 2.0;
            [developer setFrameSize:size];

            // center in view
            CGFloat width = NSWidth([developer frame]) + 0.0;
            CGFloat y = NSMinY([developer frame]);
            CGFloat x = NSMidX([container bounds]) - width/2.0;
            [developer setFrameOrigin:(NSPoint){x, y}];

            // system / year tags
            NSButton *system = [[container subviews] objectAtIndex:2];
            [system setEnabled:NO];
            [system setTitle:[game systemShortName]];
            [system sizeToFit];

            NSButton *year = [[container subviews] objectAtIndex:3];
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            [formatter setDateFormat:@"Y"];
            [year setEnabled:NO];
            [year setHidden:[[game released] timeIntervalSince1970] == 0];
            [year setTitle:[formatter stringFromDate:[game released]]];
            [year sizeToFit];

            // center in view
            if([[game released] timeIntervalSince1970] != 0)
                width = NSWidth([system frame])+NSWidth([year frame]) + 5.0;
            else width = NSWidth([system frame]);
            y = NSMinY([system frame]);

            x = NSMidX([container bounds]) - width/2.0;
            [system setFrameOrigin:(NSPoint){x, y}];
            x += NSWidth([system frame]) + 5.0;
            [year setFrameOrigin:(NSPoint){x, y}];
        }];
    }
    else
    {
        view = [tableView makeViewWithIdentifier:@"GameView" owner:self];
        NSArray *subviews = [view subviews];

        OEFeaturedGame *game = [self tableView:tableView objectValueForTableColumn:tableColumn row:row];

        NSTextField *titleField = [subviews objectAtIndex:0];
        [titleField setStringValue:[game name]];

        // system / year flags
        NSButton    *system  = [subviews objectAtIndex:1];
        [system setEnabled:NO];
        [system setTitle:[game systemShortName]];
        [system sizeToFit];

        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"Y"];
        NSButton    *year  = [subviews objectAtIndex:2];
        [year setHidden:[[game released] timeIntervalSince1970] == 0];
        [year setTitle:[formatter stringFromDate:[game released]]];
        [year setEnabled:NO];
        [year sizeToFit];
        [year setFrameOrigin:(NSPoint){NSMaxX([system frame])+5.0, NSMinY([system frame])}];

        // description
        NSScrollView *descriptionScroll = [subviews objectAtIndex:3];
        NSTextView *description = [descriptionScroll documentView];

        [description setString:[game gameDescription] ?: @""];
        NSInteger length = [[description textStorage] length];
        NSDictionary *attributes = [self descriptionStringAttributes];
        [[description textStorage] setAttributes:attributes range:NSMakeRange(0, length)];
        [description sizeToFit];

        NSButton    *developer = [subviews objectAtIndex:5];
        [developer setTarget:self];
        [developer setAction:@selector(gotoDeveloperWebsite:)];
        [developer setObjectValue:[game website]];
        [developer setTitle:[game developer]];
        [developer sizeToFit];
        [developer setFrameSize:NSMakeSize([developer frame].size.width, [developer frame].size.height)];

        OEFeaturedGamesCoverView *imagesView = [subviews objectAtIndex:4];
        [imagesView setURLs:[game images]];
        [imagesView setTarget:self];
        [imagesView setDoubleAction:@selector(launchGame:)];
    }

    return view;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row
{
    if(row == 0 || row == 2)
        return 94.0;
    if(row == 1)
        return 230.0; // adjusts inset

    CGFloat textHeight = 0.0;
    OEFeaturedGame *game = [self tableView:tableView objectValueForTableColumn:nil row:row];
    NSString *gameDescription = [game gameDescription];
    if(gameDescription)
    {
        NSDictionary *attributes = [self descriptionStringAttributes];
        NSAttributedString *string = [[NSAttributedString alloc] initWithString:gameDescription attributes:attributes];

        CGFloat width = NSWidth([tableView bounds]) - 2*TableViewSpacing -DescriptionX;
        textHeight = [string heightForWidth:width] + 120.0; // fixes overlapping description rows
    }

    return MAX(220.0, textHeight);
}
#pragma mark - TableView Delegate
- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row
{
    return NO;
}

#pragma mark - State Handling
- (id)encodeCurrentState
{
    return nil;
}

- (void)restoreState:(id)state
{}

- (void)setLibraryController:(OELibraryController *)libraryController
{
    _libraryController = libraryController;

    [[libraryController toolbarFlowViewButton] setEnabled:NO];
    [[libraryController toolbarGridViewButton] setEnabled:NO];
    [[libraryController toolbarListViewButton] setEnabled:NO];

    [[libraryController toolbarSearchField] setEnabled:NO];

    [[libraryController toolbarSlider] setEnabled:NO];
}
@end

@implementation OEFeaturedGame
- (instancetype)initWithNode:(NSXMLNode*)node
{
    self = [super init];
    if(self)
    {
#define StringValue(_XPATH_)  [[[[node nodesForXPath:_XPATH_ error:nil] lastObject] stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
#define IntegerValue(_XPATH_) [StringValue(_XPATH_) integerValue]
#define DateValue(_XPATH_)    [NSDate dateWithTimeIntervalSince1970:IntegerValue(_XPATH_)]

        _name            = StringValue(@"@name");
        _developer       = StringValue(@"@developer");
        _website         = StringValue(@"@website");
        _fileURLString   = StringValue(@"@file");
        _fileIndex       = IntegerValue(@"@fileIndex");
        _gameDescription = StringValue(@"description");
        _added           = DateValue(@"@added");
        _released        = DateValue(@"@released");
        _systemIdentifier = StringValue(@"@system");
        _md5             = StringValue(@"@md5");

        NSArray *images = [node nodesForXPath:@"images/image" error:nil];
        _images = [images arrayByEvaluatingBlock:^id(NSXMLNode *node, NSUInteger idx, BOOL *stop) {
            return [NSURL URLWithString:StringValue(@"@src")];
        }];

#undef StringValue
#undef IntegerValue
#undef DateValue
    }
    return self;
}

- (NSString*)systemShortName
{
    NSString *identifier = [self systemIdentifier];
    NSManagedObjectContext *context = [[OELibraryDatabase defaultDatabase] mainThreadContext];

    OEDBSystem *system = [OEDBSystem systemForPluginIdentifier:identifier inContext:context];
    if([[system shortname] length] != 0)
        return [system shortname];

    return [[[identifier componentsSeparatedByString:@"."] lastObject] uppercaseString];
}
@end


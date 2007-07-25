//
//  MPController.m
//  MarcoPolo
//
//  Created by David Symonds on 1/02/07.
//

#include "Growl/GrowlApplicationBridge.h"

#import "Action.h"
#import "ContextsDataSource.h"
#import "DSLogger.h"
#import "EvidenceSource.h"
#import "MPController.h"

#import "NetworkLocationAction.h"



@interface MPController (Private)

- (void)showInStatusBar:(id)sender;
- (void)hideFromStatusBar:(NSTimer *)theTimer;
- (void)doGrowl:(NSString *)title withMessage:(NSString *)message;
- (void)contextsChanged:(NSNotification *)notification;

- (void)doUpdate:(NSTimer *)theTimer;

- (void)updateThread:(id)arg;

- (NSDictionary *)registrationDictionaryForGrowl;
- (NSString *)applicationNameForGrowl;

- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag;

- (void)userDefaultsChanged:(NSNotification *)notification;

@end

#pragma mark -

@implementation MPController

#define STATUS_BAR_LINGER	10	// seconds before disappearing from menu bar



+ (void)initialize
{
	NSMutableDictionary *appDefaults = [NSMutableDictionary dictionary];

	[appDefaults setValue:[NSNumber numberWithBool:YES] forKey:@"Enabled"];
	[appDefaults setValue:[NSNumber numberWithDouble:0.75] forKey:@"MinimumConfidenceRequired"];
	[appDefaults setValue:[NSNumber numberWithBool:YES] forKey:@"ShowGuess"];
	[appDefaults setValue:[NSNumber numberWithBool:NO] forKey:@"EnableSwitchSmoothing"];
	[appDefaults setValue:[NSNumber numberWithBool:NO] forKey:@"HideStatusBarIcon"];

	// TODO: spin these into the EvidenceSourceSetController?
	[appDefaults setValue:[NSNumber numberWithBool:YES] forKey:@"EnableAudioOutputEvidenceSource"];
	[appDefaults setValue:[NSNumber numberWithBool:NO] forKey:@"EnableBluetoothEvidenceSource"];
	[appDefaults setValue:[NSNumber numberWithBool:NO] forKey:@"EnableFireWireEvidenceSource"];
	[appDefaults setValue:[NSNumber numberWithBool:YES] forKey:@"EnableIPEvidenceSource"];
	[appDefaults setValue:[NSNumber numberWithBool:NO] forKey:@"EnableLightEvidenceSource"];
	[appDefaults setValue:[NSNumber numberWithBool:YES] forKey:@"EnableMonitorEvidenceSource"];
	[appDefaults setValue:[NSNumber numberWithBool:YES] forKey:@"EnablePowerEvidenceSource"];
	[appDefaults setValue:[NSNumber numberWithBool:YES] forKey:@"EnableRunningApplicationEvidenceSource"];
	[appDefaults setValue:[NSNumber numberWithBool:YES] forKey:@"EnableTimeOfDayEvidenceSource"];
	[appDefaults setValue:[NSNumber numberWithBool:YES] forKey:@"EnableUSBEvidenceSource"];
	[appDefaults setValue:[NSNumber numberWithBool:NO] forKey:@"EnableWiFiEvidenceSource"];

	[appDefaults setValue:[NSNumber numberWithBool:NO] forKey:@"UseDefaultContext"];

	// Advanced
	[appDefaults setValue:[NSNumber numberWithBool:NO] forKey:@"ShowAdvancedPreferences"];
	[appDefaults setValue:[NSNumber numberWithFloat:5.0] forKey:@"UpdateInterval"];
	[appDefaults setValue:[NSNumber numberWithBool:NO] forKey:@"WiFiAlwaysScans"];

	// Sparkle (TODO: make update time configurable?)
	[appDefaults setValue:[NSNumber numberWithBool:YES] forKey:@"SUCheckAtStartup"];

	[[NSUserDefaults standardUserDefaults] registerDefaults:appDefaults];
}

// Helper: Load a named image, and scale it to be suitable for menu bar use.
- (NSImage *)prepareImageForMenubar:(NSString *)name
{
	NSImage *img = [NSImage imageNamed:name];
	[img setScalesWhenResized:YES];
	[img setSize:NSMakeSize(18, 18)];

	return img;
}

- (id)init
{
	if (!(self = [super init]))
		return nil;

	// Growl registration
	[GrowlApplicationBridge setGrowlDelegate:self];

	sbImage = [self prepareImageForMenubar:@"mp-icon"];
	sbItem = nil;
	sbHideTimer = nil;

	updatingSwitchingLock = [[NSLock alloc] init];
	updatingLock = [[NSConditionLock alloc] initWithCondition:0];
	timeToDie = FALSE;
	smoothCounter = 0;

	// Set placeholder values
	[self setValue:@"" forKey:@"currentContextUUID"];
	[self setValue:@"?" forKey:@"currentContextName"];
	[self setValue:@"?" forKey:@"guessConfidence"];

	[self setValue:[NSNumber numberWithBool:NO] forKey:@"forcedContextIsSticky"];

	return self;
}

- (void)dealloc
{
	[updatingSwitchingLock release];
	[updatingLock release];

	[super dealloc];
}

- (void)awakeFromNib
{
	// If there aren't any contexts defined, populate list from network locations
	if ([[[NSUserDefaults standardUserDefaults] arrayForKey:@"Contexts"] count] == 0) {
		NSArray *limitedOptions = [NetworkLocationAction limitedOptions];
		NSEnumerator *en = [limitedOptions objectEnumerator];
		NSDictionary *dict;
		NSMutableDictionary *lookup = [NSMutableDictionary dictionary];
		while ((dict = [en nextObject])) {
			Context *ctxt = [contextsDataSource newContextWithName:[dict valueForKey:@"option"] fromUI:NO];
			[lookup setObject:ctxt forKey:[ctxt name]];
		}
		NSLog(@"Quickstart: Created %d contexts", [limitedOptions count]);

		// Additionally, if there are no actions, populate list with NetworkLocationActions
		if ([[[NSUserDefaults standardUserDefaults] arrayForKey:@"Actions"] count] == 0) {
			NSMutableArray *actions = [NSMutableArray array];
			en = [lookup objectEnumerator];
			Context *ctxt;
			while ((ctxt = [en nextObject])) {
				Action *act = [[[NetworkLocationAction alloc] initWithOption:[ctxt name]] autorelease];
				NSMutableDictionary *act_dict = [act dictionary];
				[act_dict setValue:[ctxt uuid] forKey:@"context"];
				[act_dict setValue:NSLocalizedString(@"Sample action", @"") forKey:@"description"];
				[actions addObject:act_dict];
			}
			[[NSUserDefaults standardUserDefaults] setObject:actions forKey:@"Actions"];
			NSLog(@"Quickstart: Created %d NetworkLocation actions", [actions count]);
		}
	}

	[[NSNotificationCenter defaultCenter] addObserver:self
						 selector:@selector(contextsChanged:)
						     name:@"ContextsChangedNotification"
						   object:contextsDataSource];
	[self contextsChanged:nil];

	[[NSNotificationCenter defaultCenter] addObserver:self
						 selector:@selector(userDefaultsChanged:)
						     name:NSUserDefaultsDidChangeNotification
						   object:nil];

	// Set up status bar.
	[self showInStatusBar:self];

	[NSThread detachNewThreadSelector:@selector(updateThread:)
				 toTarget:self
			       withObject:nil];

	// Start up evidence sources that should be started
	[evidenceSources startOrStopAll];

	// Schedule a one-off timer (in 2s) to get initial data.
	// Future recurring timers will be set automatically from there.
	[NSTimer scheduledTimerWithTimeInterval:(NSTimeInterval)2
					 target:self
				       selector:@selector(doUpdate:)
				       userInfo:nil
					repeats:NO];

	[NSApp unhide];
}

- (void)setStatusTitle:(NSString *)title
{
	if (!sbItem)
		return;
	if (!title) {
		[sbItem setTitle:nil];
		return;
	}

	// Smaller font
	NSFont *font = [NSFont menuBarFontOfSize:10.0];
	NSDictionary *attrs = [NSDictionary dictionaryWithObject:font
							  forKey:NSFontAttributeName];
	NSAttributedString *as = [[NSAttributedString alloc] initWithString:title attributes:attrs];
	[sbItem setAttributedTitle:[as autorelease]];
}

- (void)showInStatusBar:(id)sender
{
	if (sbItem) {
		// Already there? Rebuild it anyway.
		[[NSStatusBar systemStatusBar] removeStatusItem:sbItem];
		[sbItem release];
	}

	sbItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
	[sbItem retain];
	[sbItem setHighlightMode:YES];
	[sbItem setImage:sbImage];
	[sbItem setMenu:sbMenu];
}

- (void)hideFromStatusBar:(NSTimer *)theTimer
{
	if (![[NSUserDefaults standardUserDefaults] boolForKey:@"HideStatusBarIcon"])
		return;

	[[NSStatusBar systemStatusBar] removeStatusItem:sbItem];
	[sbItem release];
	sbItem = nil;
	sbHideTimer = nil;
}

- (void)doGrowl:(NSString *)title withMessage:(NSString *)message
{
	float pri = 0;

	if ([title isEqualToString:@"Failure"])
		pri = 1;

	[GrowlApplicationBridge notifyWithTitle:title
				    description:message
			       notificationName:title
				       iconData:nil
				       priority:pri
				       isSticky:NO
				   clickContext:nil];
}

- (void)contextsChanged:(NSNotification *)notification
{
	// Fill in 'Force context' submenu
	NSMenu *submenu = [[[NSMenu alloc] init] autorelease];
	NSEnumerator *en = [[contextsDataSource orderedTraversal] objectEnumerator];
	Context *ctxt;
	while ((ctxt = [en nextObject])) {
		NSMenuItem *item = [[[NSMenuItem alloc] init] autorelease];
		[item setTitle:[ctxt name]];
		[item setIndentationLevel:[[ctxt valueForKey:@"depth"] intValue]];
		[item setRepresentedObject:[ctxt uuid]];
		[item setTarget:self];
		[item setAction:@selector(forceSwitchAndUnstick:)];
		[submenu addItem:item];

		item = [[item copy] autorelease];
		[item setTitle:[NSString stringWithFormat:@"%@ (*)", [item title]]];
		[item setKeyEquivalentModifierMask:NSAlternateKeyMask];
		[item setAlternate:YES];
		[item setAction:@selector(forceSwitchAndStick:)];
		[submenu addItem:item];
	}
	{
		// Unstick menu item
		NSMenuItem *item = [[[NSMenuItem alloc] init] autorelease];
		[item setTitle:NSLocalizedString(@"Unstick forced context", @"")];
		[item setTarget:self];
		[item setAction:@selector(unstickForcedContext:)];
		[item bind:@"enabled" toObject:self withKeyPath:@"forcedContextIsSticky" options:nil];

		[submenu addItem:[NSMenuItem separatorItem]];
		[submenu addItem:item];
	}
	[forceContextMenuItem setSubmenu:submenu];

	// Update current context details
	ctxt = [contextsDataSource contextByUUID:currentContextUUID];
	if (ctxt) {
		[self setValue:[ctxt name] forKey:@"currentContextName"];
	} else {
		// Our current context was removed
		[self setValue:@"" forKey:@"currentContextUUID"];
		[self setValue:@"?" forKey:@"currentContextName"];
		[self setValue:@"?" forKey:@"guessConfidence"];
	}
	if ([[NSUserDefaults standardUserDefaults] boolForKey:@"ShowGuess"])
		[self setStatusTitle:[contextsDataSource pathFromRootTo:currentContextUUID]];

	// TODO: update other stuff?
}

#pragma mark Rule matching and Action triggering

- (void)doUpdate:(NSTimer *)theTimer
{
	// Check timer interval
	NSTimeInterval intv = [[NSUserDefaults standardUserDefaults] floatForKey:@"UpdateInterval"];
	if (fabs(intv - [theTimer timeInterval]) > 0.1) {
		if ([theTimer isValid])
			[theTimer invalidate];
		[NSTimer scheduledTimerWithTimeInterval:intv
						 target:self
					       selector:@selector(doUpdate:)
					       userInfo:nil
						repeats:YES];
	}

	// Check status bar visibility
	BOOL hide = [[NSUserDefaults standardUserDefaults] boolForKey:@"HideStatusBarIcon"];
	if (sbItem && hide && !sbHideTimer)
		sbHideTimer = [NSTimer scheduledTimerWithTimeInterval:(NSTimeInterval)STATUS_BAR_LINGER
						 target:self
					       selector:@selector(hideFromStatusBar:)
					       userInfo:nil
						repeats:NO];
	else if (!hide && sbHideTimer) {
		[sbHideTimer invalidate];
		sbHideTimer = nil;
	}
	if (!hide && !sbItem)
		[self showInStatusBar:self];

	[updatingLock lock];
	//[sbItem setImage:imageActive];
	[updatingLock unlockWithCondition:1];
}

- (NSArray *)getRulesThatMatch
{
	NSArray *rules = [rulesController arrangedObjects];
	NSMutableArray *matching_rules = [NSMutableArray array];

	NSEnumerator *rule_enum = [rules objectEnumerator];
	NSDictionary *rule;
	while (rule = [rule_enum nextObject]) {
		if ([evidenceSources ruleMatches:rule])
			[matching_rules addObject:rule];
	}

	return matching_rules;
}

// (Private) in a new thread, execute Action immediately, growling upon failure
- (void)executeAction:(id)arg
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	Action *action = (Action *) arg;

	NSString *errorString;
	if (![action execute:&errorString])
		[self doGrowl:NSLocalizedString(@"Failure", @"Growl message title") withMessage:errorString];

	[pool release];
}

// (Private) in a new thread
// Parameter is an NSArray of actions; delay will be taken from the first one
- (void)executeActionSetWithDelay:(id)arg
{
	NSArray *actions = (NSArray *) arg;
	if ([actions count] == 0)
		return;

	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

	NSTimeInterval delay = [[[actions objectAtIndex:0] valueForKey:@"delay"] doubleValue];
	[NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:delay]];

	// Aggregate growl messages
	NSString *growlTitle = NSLocalizedString(@"Performing Action", @"Growl message title");
	NSString *growlMessage = [[actions objectAtIndex:0] description];
	if ([actions count] > 1) {
		growlTitle = NSLocalizedString(@"Performing Actions", @"Growl message title");
		growlMessage = [NSString stringWithFormat:@"* %@", [actions componentsJoinedByString:@"\n* "]];
	}
	[self doGrowl:growlTitle withMessage:growlMessage];

	NSEnumerator *en = [actions objectEnumerator];
	Action *action;
	while ((action = [en nextObject]))
		[NSThread detachNewThreadSelector:@selector(executeAction:)
					 toTarget:self
				       withObject:action];

	[pool release];
}

// (Private) This will group the growling together. The parameter should be an array of Action objects.
- (void)executeActionSet:(NSMutableArray *)actions
{
	if ([actions count] == 0)
		return;

	static double batchThreshold = 0.25;		// maximum grouping interval size

	// Sort by delay
	[actions sortUsingSelector:@selector(compareDelay:)];

	NSMutableArray *batch = [NSMutableArray array];
	NSEnumerator *en = [actions objectEnumerator];
	Action *action;
	while ((action = [en nextObject])) {
		if ([batch count] == 0) {
			[batch addObject:action];
			continue;
		}
		double maxBatchDelay = [[[batch objectAtIndex:0] valueForKey:@"delay"] doubleValue] + batchThreshold;
		if ([[action valueForKey:@"delay"] doubleValue] < maxBatchDelay) {
			[batch addObject:action];
			continue;
		}
		// Completed a batch
		[NSThread detachNewThreadSelector:@selector(executeActionSetWithDelay:)
					 toTarget:self
				       withObject:batch];
		batch = [NSMutableArray arrayWithObject:action];
		continue;
	}

	// Final batch
	if ([batch count] > 0)
		[NSThread detachNewThreadSelector:@selector(executeActionSetWithDelay:)
					 toTarget:self
				       withObject:batch];
}

- (void)triggerDepartureActions:(NSString *)fromUUID
{
	NSArray *actions = [actionsController arrangedObjects];
	NSMutableArray *actionsToRun = [NSMutableArray array];
	int max_delay = 0;

	// This is slightly trickier than triggerArrivalActions, since the "delay" value is
	// a reverse delay, rather than a forward delay. We scan through the actions, finding
	// all the ones that need to be run, calculating the maximum delay along the way.
	// We then go through those selected actions, and run a surrogate action for each with
	// a delay equal to (max_delay - original_delay).

	NSEnumerator *action_enum = [actions objectEnumerator];
	NSDictionary *action;
	while ((action = [action_enum nextObject])) {
		if (![[action objectForKey:@"when"] isEqualToString:@"Departure"])
			continue;
		if (![[action objectForKey:@"context"] isEqualToString:fromUUID])
			continue;
		if (![[action objectForKey:@"enabled"] boolValue])
			continue;

		NSNumber *aDelay;
		if ((aDelay = [action valueForKey:@"delay"])) {
			if ([aDelay doubleValue] > max_delay)
				max_delay = [aDelay doubleValue];
		}

		[actionsToRun addObject:action];

	}

	action_enum = [actionsToRun objectEnumerator];
	NSMutableArray *set = [NSMutableArray array];
	while ((action = [action_enum nextObject])) {
		NSMutableDictionary *surrogateAction = [NSMutableDictionary dictionaryWithDictionary:action];
		double original_delay = [[action valueForKey:@"delay"] doubleValue];
		[surrogateAction setValue:[NSNumber numberWithDouble:(max_delay - original_delay)]
				   forKey:@"delay"];
		[set addObject:[Action actionFromDictionary:surrogateAction]];
	}
	[self executeActionSet:set];

	// Finally, we have to sleep this thread, so we don't return until we're ready to change contexts.
	[NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:max_delay]];
}

- (void)triggerArrivalActions:(NSString *)toUUID
{
	NSArray *actions = [actionsController arrangedObjects];

	NSEnumerator *action_enum = [actions objectEnumerator];
	NSDictionary *action;
	NSMutableArray *set = [NSMutableArray array];
	while (action = [action_enum nextObject]) {
		if (![[action objectForKey:@"when"] isEqualToString:@"Arrival"])
			continue;
		if (![[action objectForKey:@"context"] isEqualToString:toUUID])
			continue;
		if (![[action objectForKey:@"enabled"] boolValue])
			continue;
		[set addObject:[Action actionFromDictionary:action]];
	}

	[self executeActionSet:set];
}

#pragma mark Context switching

- (void)performTransitionFrom:(NSString *)fromUUID to:(NSString *)toUUID
{
	NSArray *walks = [contextsDataSource walkFrom:fromUUID to:toUUID];
	NSArray *leaving_walk = [walks objectAtIndex:0];
	NSArray *entering_walk = [walks objectAtIndex:1];
	NSEnumerator *en;
	Context *ctxt;

	[updatingSwitchingLock lock];

	// Execute all the "Departure" actions
	en = [leaving_walk objectEnumerator];
	while ((ctxt = [en nextObject])) {
		DSLog(@"Depart from %@", [ctxt name]);
		[self triggerDepartureActions:[ctxt uuid]];
	}

	// Update current context
	[self setValue:toUUID forKey:@"currentContextUUID"];
	ctxt = [contextsDataSource contextByUUID:toUUID];
	NSString *ctxt_path = [contextsDataSource pathFromRootTo:toUUID];
	[self doGrowl:NSLocalizedString(@"Changing Context", @"Growl message title")
	  withMessage:[NSString stringWithFormat:NSLocalizedString(@"Changing to context '%@' %@.",
								   @"First parameter is the context name, second parameter is the confidence value, or 'as default context'"),
			ctxt_path, guessConfidence]];
	[self setValue:ctxt_path forKey:@"currentContextName"];
	if ([[NSUserDefaults standardUserDefaults] boolForKey:@"ShowGuess"])
		[self setStatusTitle:ctxt_path];

	// Update force context menu
	NSMenu *menu = [forceContextMenuItem submenu];
	en = [[menu itemArray] objectEnumerator];
	NSMenuItem *item;
	while ((item = [en nextObject])) {
		BOOL ticked = ([[item representedObject] isEqualToString:toUUID]);
		[item setState:(ticked ? NSOnState : NSOffState)];
	}

	// Execute all the "Arrival" actions
	en = [entering_walk objectEnumerator];
	while ((ctxt = [en nextObject])) {
		DSLog(@"Arrive at %@", [ctxt name]);
		[self triggerArrivalActions:[ctxt uuid]];
	}

	[updatingSwitchingLock unlock];

	return;
}

- (void)forceSwitch:(id)sender
{
	Context *ctxt = [contextsDataSource contextByUUID:[sender representedObject]];
	DSLog(@"going to %@", [ctxt name]);
	[self setValue:NSLocalizedString(@"(forced)", @"Used when force-switching to a context")
		forKey:@"guessConfidence"];

	[self performTransitionFrom:currentContextUUID to:[ctxt uuid]];
}

- (void)forceSwitchAndStick:(id)sender
{
	[self setValue:[NSNumber numberWithBool:YES] forKey:@"forcedContextIsSticky"];
	[self forceSwitch:sender];
}

- (void)forceSwitchAndUnstick:(id)sender
{
	[self setValue:[NSNumber numberWithBool:NO] forKey:@"forcedContextIsSticky"];
	[self forceSwitch:sender];
}

- (void)unstickForcedContext:(id)sender
{
	[self setValue:[NSNumber numberWithBool:NO] forKey:@"forcedContextIsSticky"];
}

#pragma mark Thread stuff

- (void)doUpdateForReal
{
	NSArray *contexts = [contextsDataSource arrayOfUUIDs];

	// Maps a guessed context to an "unconfidence" value, which is
	// equal to (1 - confidence). We step through all the rules that are "hits",
	// and multiply this running unconfidence value by (1 - rule.confidence).
	NSMutableDictionary *guesses = [NSMutableDictionary dictionaryWithCapacity:[contexts count]];
	NSArray *rule_hits = [self getRulesThatMatch];

	NSEnumerator *en = [rule_hits objectEnumerator];
	NSDictionary *rule;
	while (rule = [en nextObject]) {
		// Rules apply to the stated context, as well as any subcontexts. We very slightly decay the amount
		// credited (proportional to the depth below the stated context), so that we don't guess a more
		// detailed context than is warranted.
		NSArray *ctxts = [contextsDataSource orderedTraversalRootedAt:[rule valueForKey:@"context"]];
		if ([ctxts count] == 0)
			continue;	// Oops, something got busted along the way
		NSEnumerator *en = [ctxts objectEnumerator];
		Context *ctxt;
		int base_depth = [[[ctxts objectAtIndex:0] valueForKey:@"depth"] intValue];
		while ((ctxt = [en nextObject])) {
			NSString *uuid = [ctxt uuid];
			int depth = [[ctxt valueForKey:@"depth"] intValue];
			double decay = 1.0 - (0.03 * (depth - base_depth));

			NSNumber *uncon = [guesses objectForKey:uuid];
			if (!uncon)
				uncon = [NSNumber numberWithDouble:1.0];
			double mult = [[rule valueForKey:@"confidence"] doubleValue] * decay;
			uncon = [NSNumber numberWithDouble:[uncon doubleValue] * (1.0 - mult)];
#ifdef DEBUG_MODE
			//NSLog(@"crediting '%@' (d=%d|%d) with %.5f\t-> %@", [ctxt name], depth, base_depth, mult, uncon);
#endif
			[guesses setObject:uncon forKey:uuid];
		}
	}

	// Guess context with lowest unconfidence
	en = [guesses keyEnumerator];
	NSString *uuid, *guess = nil;
	double guessConf = 0.0;
	while ((uuid = [en nextObject])) {
		double uncon = [[guesses objectForKey:uuid] doubleValue];
		if (((1.0 - uncon) > guessConf) || !guess) {
			guess = uuid;
			guessConf = 1.0 - uncon;
		}
	}

	//---------------------------------------------------------------
	NSNumberFormatter *nf = [[[NSNumberFormatter alloc] init] autorelease];
	[nf setFormatterBehavior:NSNumberFormatterBehavior10_4];
	[nf setNumberStyle:NSNumberFormatterPercentStyle];
	NSString *perc = [nf stringFromNumber:[NSDecimalNumber numberWithDouble:guessConf]];
	NSString *guessConfidenceString = [NSString stringWithFormat:
		NSLocalizedString(@"with confidence %@", @"Appended to a context-change notification"),
		perc];
	BOOL do_title = [[NSUserDefaults standardUserDefaults] boolForKey:@"ShowGuess"];
	if (!do_title)
		[self setStatusTitle:nil];
	NSString *guessString = [[contextsDataSource contextByUUID:guess] name];

	BOOL no_guess = NO;
	if (!guess) {
#ifdef DEBUG_MODE
		DSLog(@"No guess made.");
#endif
		no_guess = YES;
	} else if (guessConf < [[NSUserDefaults standardUserDefaults] floatForKey:@"MinimumConfidenceRequired"]) {
#ifdef DEBUG_MODE
		DSLog(@"Guess of '%@' isn't confident enough: only %@.", guessString, guessConfidenceString);
#endif
		no_guess = YES;
	}

	if (no_guess) {
		if (![[NSUserDefaults standardUserDefaults] boolForKey:@"UseDefaultContext"])
			return;
		guess = [[NSUserDefaults standardUserDefaults] stringForKey:@"DefaultContext"];
		guessConfidenceString = NSLocalizedString(@"as default context",
							  @"Appended to a context-change notification");
		guessString = [[contextsDataSource contextByUUID:guess] name];
	}

	BOOL do_switch = YES;

	BOOL smoothing = [[NSUserDefaults standardUserDefaults] boolForKey:@"EnableSwitchSmoothing"];
	if (smoothing && ![currentContextUUID isEqualToString:guess]) {
		if (smoothCounter == 0) {
			smoothCounter = 1;	// Make this customisable?
			do_switch = NO;
		} else if (--smoothCounter > 0)
			do_switch = NO;
#ifdef DEBUG_MODE
		if (!do_switch)
			DSLog(@"Switch smoothing kicking in... (%@ != %@)", currentContextName, guessString);
#endif
	}

	[self setValue:guessConfidenceString forKey:@"guessConfidence"];

	if (!do_switch)
		return;

	if ([guess isEqualToString:currentContextUUID]) {
#ifdef DEBUG_MODE
		DSLog(@"Guessed '%@' (%@); already there.", guessString, guessConfidenceString);
#endif
		return;
	}

	[self performTransitionFrom:currentContextUUID to:guess];
}

- (void)updateThread:(id)arg
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

	while (!timeToDie) {
		[updatingLock lockWhenCondition:1];

		if ([[NSUserDefaults standardUserDefaults] boolForKey:@"Enabled"] &&
		    ![[self valueForKey:@"forcedContextIsSticky"] boolValue]) {
			[self doUpdateForReal];

			// Flush auto-release pool
			[pool release];
			pool = [[NSAutoreleasePool alloc] init];
		}

//end_of_update:
		//[sbItem setImage:imageIdle];
		[updatingLock unlockWithCondition:0];
	}

	[pool release];
}

//////////////////////////////////////////////////////////////////////////////////////////////////////

#pragma mark -
#pragma mark Growl delegates

- (NSDictionary *) registrationDictionaryForGrowl
{
	NSArray *notifications = [NSArray arrayWithObjects:
					NSLocalizedString(@"Changing Context", @"Growl message title"),
					NSLocalizedString(@"Performing Action", @"Growl message title"),
					NSLocalizedString(@"Performing Actions", @"Growl message title"),
					NSLocalizedString(@"Failure", @"Growl message title"),
					//NSLocalizedString(@"Evidence Change", @"Growl message title"),
					nil];

	return [NSDictionary dictionaryWithObjectsAndKeys:
		notifications, GROWL_NOTIFICATIONS_ALL,
		notifications, GROWL_NOTIFICATIONS_ALL,
		nil];
}

- (NSString *) applicationNameForGrowl
{
	return @"MarcoPolo";
}

#pragma mark NSApplication delegates

- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag
{
	// Set up status bar.
	if ([[NSUserDefaults standardUserDefaults] boolForKey:@"HideStatusBarIcon"]) {
		[self showInStatusBar:self];
		sbHideTimer = [NSTimer scheduledTimerWithTimeInterval:(NSTimeInterval)STATUS_BAR_LINGER
						 target:self
					       selector:@selector(hideFromStatusBar:)
					       userInfo:nil
						repeats:NO];
	}

	return YES;
}

#pragma mark NSUserDefaults notifications

- (void)userDefaultsChanged:(NSNotification *)notification
{
#ifndef DEBUG_MODE
	// Force write of preferences
	[[NSUserDefaults standardUserDefaults] synchronize];
#endif

	// Check that the running evidence sources match the defaults
	[evidenceSources startOrStopAll];
}

@end

#import <Cocoa/Cocoa.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreServices/CoreServices.h>
#import <Foundation/NSDictionary.h>
#include <QuickLook/QuickLook.h>

#import <Zip/ZipArchive.h>
#import <RegexKit/RegexKit.h>

#define LINE_BUFFER_SIZE 80 // see JAR File Specification

// this simple application will only operate on a couple of variables, let's make them global
ZipArchive *archive;
NSMutableDictionary* bundleHeaders;

// formats a package definition as given in Import-Package or Export-Package
NSString* formatPackageString(NSString *headerValue) {
	static NSString* packageNameRegex = @"(^|,)([a-zA-Z0-9\\.]+)(;[a-zA-Z\\-:=]+\"[^\"]+\")?";
	
	NSMutableString* formattedString = [[[NSMutableString alloc] init] autorelease];
	RKEnumerator *matches = [headerValue matchEnumeratorWithRegex: packageNameRegex];
	NSRange currentRange = [matches nextRangeForCapture:2];
	while (currentRange.location != NSNotFound) {
		[formattedString appendFormat:@"%@<br/>", [headerValue substringWithRange: currentRange]];
		currentRange = [matches nextRangeForCapture:2];
	}
	return formattedString;
}

// a simple structure to define the names of bundle headers and how they should be formatted
typedef NSString* (*HeaderFormatFunction)(NSString*);
typedef struct _HeaderDescription {
    NSString *name;
	NSString *formatString;
	HeaderFormatFunction formatFunction;
} HeaderDescription;

// the actual header definitions
#define FIRST_HEADER_IN_TABLE 8 // change these after changing the header descriptions
#define HEADER_COUNT 11
HeaderDescription headerDescriptions[] = {
	// since the OSGi spec states that Bundle-ManifestVersion must be 2, remove it
	{@"Bundle-ManifestVersion", @"", NULL},
	{@"Manifest-Version", @"", NULL},
	{@"Bundle-Name", @"<h1>%@</h1>", NULL},
	{@"Bundle-SymbolicName", @"<h2>%@</h2>", NULL},
	{@"Bundle-Version", @"<h4>Version: %@</h4>", NULL},
	{@"Bundle-Vendor", @"<h4>Vendor: %@</h4>", NULL},
	{@"Bundle-Description", @"<div class=\"description\">%@</div>", NULL},
	{@"Bundle-ActivationPolicy", @"<div class=\"tr\"><div class=\"td\">Activation policy:</div><div class=\"td\">%@</div></div>", NULL},
	{@"Bundle-Activator", @"<div class=\"tr\"><div class=\"td\">Activator class:</div><div class=\"td\">%@</div></div>", NULL},
	{@"Export-Package", @"<div class=\"tr\"><div class=\"td\">Exported packages:</div><div class=\"td\">%@</div></div>", formatPackageString},
	{@"Import-Package", @"<div class=\"tr\"><div class=\"td\">Imported packages:</div><div class=\"td\">%@</div></div>", formatPackageString}
};

/* -----------------------------------------------------------------------------
   Formats the header identified by the given index and appends it to the target
   string
   ----------------------------------------------------------------------------- */
void appendHeader(NSMutableString *target, int header) {
	HeaderDescription currentHeader = headerDescriptions[header];
	NSString *headerValue = [bundleHeaders objectForKey:currentHeader.name];
	if (headerValue != NULL) {
		if (currentHeader.formatFunction != NULL) {
			headerValue = (*currentHeader.formatFunction)(headerValue);
		}
		[target appendFormat:currentHeader.formatString, headerValue];
		[bundleHeaders removeObjectForKey:currentHeader.name];
	}
}


/* -----------------------------------------------------------------------------
   Reads a bundle manifest and stores its headers in a NSMutableDictionary
   ----------------------------------------------------------------------------- */
void readBundleManifest(FILE *bundleManifest) {
	bundleHeaders = [[[NSMutableDictionary alloc] init] autorelease];
	NSCharacterSet *dividerCharacters = [NSCharacterSet characterSetWithCharactersInString:@":"];

	char* buffer = (char*)malloc(sizeof(char)*LINE_BUFFER_SIZE);

	NSString *currentHeaderName = NULL;
	NSMutableString *currentHeaderValue = NULL;
	
	while (NULL != fgets(buffer, LINE_BUFFER_SIZE, bundleManifest)) {
		NSString *line = [[NSString alloc] initWithUTF8String: buffer];
		if ([line length] == 0 || [line characterAtIndex:0] == '\n' || [line characterAtIndex:0] == '\r') {
			if (currentHeaderName != NULL) {
				[currentHeaderName release];
				currentHeaderName = NULL;
				[currentHeaderValue release];
				currentHeaderValue = NULL;
			}
			[line release];
			continue;
		}
		// if the first character is a whitespace, we're still continueing the same header
		if ([line characterAtIndex:0] == ' ') {
			[currentHeaderValue appendString:[line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
		} else { // the current header is complete, add it to the dictionary
			if (currentHeaderName != NULL) {
				[bundleHeaders setObject:currentHeaderValue forKey:currentHeaderName];
				// adding the values to the dictionary should have increased their reference count
				[currentHeaderValue release];
				currentHeaderValue = NULL;
				[currentHeaderName release];
				currentHeaderName = NULL;
			}
			
			// now look for the new header in the current line
			if ([line rangeOfCharacterFromSet:dividerCharacters].location == NSNotFound) {
				[line release];
				line = NULL;
				continue;
			}
			NSArray *header = [line componentsSeparatedByString:@": "];
			currentHeaderName = [[header objectAtIndex:0] retain];
			currentHeaderValue = [[NSMutableString alloc] initWithString:[[header objectAtIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
		}
		[line release];
	}
	if (currentHeaderName != NULL) {
		[currentHeaderName release];  
		[currentHeaderValue release];
	}
	free(buffer);
}

/* -----------------------------------------------------------------------------
	Create some nice HTML markup from the headers
   ----------------------------------------------------------------------------- */
NSString* createHtml(NSMutableDictionary *documentProperties) {
    [documentProperties setObject:@"UTF-8" forKey:(NSString *)kQLPreviewPropertyTextEncodingNameKey];
    [documentProperties setObject:@"text/html" forKey:(NSString *)kQLPreviewPropertyMIMETypeKey];	
	
	NSString *bundlePath = [[NSBundle bundleWithIdentifier:@"de.dudedevelopment.osgiquicklookgenerator"] bundlePath];
	NSMutableString *html = [[[NSMutableString alloc] init] autorelease];
	
	// create a static head
	[html appendString:@"<html>"];
	[html appendString:[NSString stringWithContentsOfFile:[NSString stringWithFormat:@"%@%@", bundlePath, @"/Contents/Resources/head.html"]]]; //  encoding: NSUnicodeStringEncoding error:NULL
	[html appendString:@"<body>	<div style=\"float:left; padding: 10px;\"><img src=\"cid:bundle.gif\"/></div>"];
	
	// append the headers as per header descriptions
	for (int i = 0; i < FIRST_HEADER_IN_TABLE; i++) {
		appendHeader(html, i);
	}
	[html appendString:@"<div class=\"table\">"];
	for (int i = FIRST_HEADER_IN_TABLE; i < HEADER_COUNT; i++) {
		appendHeader(html, i);
	}
	
	// create a list of classes included in the bundle
	NSMutableString *classesInBundle = [[[NSMutableString alloc] init] autorelease];
	RKRegex *classFilePattern = [RKRegex regexWithRegexString:@"^[a-zA-Z0-9/]+\\.class$" options:RKCompileNoOptions];
	for (NSString *file in [archive entries]) {
		if ([file isMatchedByRegex: classFilePattern]) {
			[classesInBundle appendFormat:@"%@<br/>", [[file substringToIndex:([file length]-6)] stringByReplacingOccurrencesOfString:@"/" withString:@"."]];
		}
	}
	
	[html appendFormat:@"<div class=\"tr\"><div class=\"td\">Included classes:</div><div class=\"td\">%@</div></div>", classesInBundle];
	
	// display remaining headers
	if ([bundleHeaders count] > 0) {
		[html appendString:@"</div><h4>Other headers:</h4><div class=\"table\">"];
		for (NSString* key in [bundleHeaders allKeys]) {
			[html appendFormat:@"<div class=\"tr\"><div class=\"td\">%@:</div><div class=\"td\">%@</div></div>", key, [bundleHeaders objectForKey:key]];
		}
	}
	[html appendString:@"</div></body></html>"];
	
	NSData *image=[NSData dataWithContentsOfFile:[NSString stringWithFormat:@"%@%@", bundlePath, @"/Contents/Resources/bundle.gif"]];

    NSMutableDictionary *imgProps=[[[NSMutableDictionary alloc] init] autorelease];
	[imgProps setObject:@"image/gif" forKey:(NSString *)kQLPreviewPropertyMIMETypeKey];
    [imgProps setObject:image forKey:(NSString *)kQLPreviewPropertyAttachmentDataKey];

	[documentProperties setObject:[NSDictionary dictionaryWithObject:imgProps forKey:@"bundle.gif"] forKey:(NSString *)kQLPreviewPropertyAttachmentsKey];
	return html;
}

/* -----------------------------------------------------------------------------
   This function gets called by QuickLook and will generate the preview for the
   bundle identified by the given URL
   ----------------------------------------------------------------------------- */
OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

	// extract the bundle manifest
	NSString* fileName = [(NSString*)CFURLCopyFileSystemPath(url, kCFURLPOSIXPathStyle) autorelease];
	archive = [[[ZipArchive alloc] initWithFile:fileName] autorelease];
	if (archive == NULL) {
		[pool release];
		NSLog(@"Could not open JAR file");
		return -1;
	}
	
	FILE *manifestFile = [archive entryNamed:@"META-INF/MANIFEST.MF"];
	if (manifestFile == NULL) {
		NSLog(@"No manifest found, not a valid JAR file");
		[pool release];
		return -1;
	} else if (QLPreviewRequestIsCancelled(preview)) {
		[pool release];
		return noErr;
	}

    NSMutableDictionary *props=[[[NSMutableDictionary alloc] init] autorelease];
	readBundleManifest(manifestFile);
	fclose(manifestFile);
		
	// return if this was no OSGi bundle (check for required header)
	if ([bundleHeaders objectForKey:@"Bundle-SymbolicName"] == NULL) {
		NSLog(@"Bundle-SymbolicName not set, not a valid OSGi bundle");
		[pool release];
		return -1;
	} else if (QLPreviewRequestIsCancelled(preview)) {
		[pool release];
		return noErr;
	}
	
	NSString* html = createHtml(props);
	QLPreviewRequestSetDataRepresentation(preview, (CFDataRef)[html dataUsingEncoding:NSUTF8StringEncoding], kUTTypeHTML, (CFDictionaryRef)props);
	
	[pool release];
    return noErr;
}

void CancelPreviewGeneration(void* thisInterface, QLPreviewRequestRef preview)
{
    // not supported
}

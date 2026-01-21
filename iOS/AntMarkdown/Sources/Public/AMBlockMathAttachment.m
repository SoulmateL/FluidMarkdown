// Copyright 2025 The FluidMarkdown Authors. All rights reserved.
// Use of this source code is governed by a Apache 2.0 license that can be
// found in the LICENSE file.

#import "AMBlockMathAttachment.h"
#import "IosMath.h"
#import "MTTypesetter.h"
#import "MTFontManager.h"
#import "AMUtils.h"

@implementation AMBlockMathAttachment
{
    MTMathList * _mathList;
    MTMathListDisplay * _displayList;
    NSArray<MTMathListDisplay *> *_wrappedDisplayLists;
    NSArray<NSNumber *> *_wrappedLineHeights;
    CGFloat _wrappedMaxWidth;
    CGFloat _wrappedTotalHeight;
    AMMathStyle * _style;
    BOOL  _isImageZeroSize;
    NSAttributedString * _mathCodeAttrText;
}

- (instancetype)initWithData:(NSData *)contentData ofType:(NSString *)uti {
    return [self initWithText:nil style:nil];
}

- (instancetype)initWithDisplayList:(nullable MTMathListDisplay *)displayList style:(nullable AMMathStyle *)style  {
    displayList.textColor = style.textColor;
    const CGFloat contentHeight = displayList.ascent + displayList.descent;
    CGFloat totalHeight = style.height;
    if (totalHeight <= 0) {
        totalHeight = contentHeight;
    }
    self = [super initWithData:nil ofType:nil];
    if (self) {
        _displayList = displayList;
        _style = style;
        _wrappedDisplayLists = nil;
        _wrappedLineHeights = nil;
        _wrappedMaxWidth = 0;
        _wrappedTotalHeight = 0;
  
        self.bounds = CGRectMake(0, 0, displayList.width, totalHeight + 1.5);
        
        CGRect rect = self.bounds;
        switch (style.verticalAlignment) {
            case UIControlContentVerticalAlignmentCenter: {
                rect.origin.y = -displayList.descent;
            }
                break;
            case UIControlContentVerticalAlignmentBottom: {
                rect.origin.y = -rect.size.height;
            }
                break;
            case UIControlContentVerticalAlignmentTop: {
                rect.origin.y = 0;
            }
                break;
            default:
                break;
        }
        self.bounds = rect;
    }
    return self;
}

- (CGFloat)lineHeightForDisplayList:(MTMathListDisplay *)displayList
{
    if (!displayList) {
        return 0;
    }
    const CGFloat contentHeight = displayList.ascent + displayList.descent;
    CGFloat totalHeight = _style.height;
    if (totalHeight <= 0) {
        totalHeight = contentHeight;
    }
    // 兼容旧逻辑：initWithDisplayList 额外 +1.5，避免渲染/像素取整导致的裁剪
    return totalHeight + 1.5;
}

- (void)updateWrappedDisplayListsIfNeededForMaxWidth:(CGFloat)maxWidth
{
    if (self.error || !_displayList) {
        return;
    }

    const CGFloat normalizedMaxWidth = floor(maxWidth);
    if (normalizedMaxWidth <= 0) {
        return;
    }

    if (fabs(normalizedMaxWidth - _wrappedMaxWidth) < 0.5 && _wrappedDisplayLists.count > 0) {
        return;
    }
    _wrappedMaxWidth = normalizedMaxWidth;

    NSMutableArray<MTMathListDisplay *> *displayLists = [NSMutableArray new];
    if (!_mathList || _displayList.width <= normalizedMaxWidth) {
        [displayLists addObject:_displayList];
    } else {
        @try {
            // 保持拆分逻辑不变：仅将 maxWidth 来源替换为真实布局宽度
            NSArray<NSNumber *> *segIndexs = [self.class getSegIndexWithDispayList:_displayList maxWidth:normalizedMaxWidth];
            NSUInteger start = 0;
            for (NSNumber *segIndex in segIndexs) {
                const NSUInteger index = segIndex.unsignedIntegerValue;
                // 保护：避免产生空行/越界（例如 segIndex = 0 会导致第一行为空、视觉上仍是一行）
                if (index <= start || index > _mathList.atoms.count) {
                    continue;
                }
                NSMutableArray<MTMathAtom *> *atoms = [NSMutableArray new];
                for (NSUInteger i = start; i < index; i++) {
                    [atoms addObject:_mathList.atoms[i]];
                }
                start = index;
                MTMathList *realMathList = [MTMathList mathListWithAtomsArray:atoms];
                MTMathListDisplay *realDisplayList = [MTTypesetter createLineForMathList:realMathList
                                                                                    font:[[MTFontManager fontManager] xitsFontWithSize:_style.fontSize]
                                                                                   style:kMTLineStyleDisplay];
                realDisplayList.textColor = _style.textColor;
                [displayLists addObject:realDisplayList];
            }

            // start 为最后一个有效切分点
            if (start < _mathList.atoms.count) {
                NSMutableArray<MTMathAtom *> *atoms = [NSMutableArray new];
                for (NSUInteger i = start; i < _mathList.atoms.count; i++) {
                    [atoms addObject:_mathList.atoms[i]];
                }
                MTMathList *realMathList = [MTMathList mathListWithAtomsArray:atoms];
                MTMathListDisplay *realDisplayList = [MTTypesetter createLineForMathList:realMathList
                                                                                    font:[[MTFontManager fontManager] xitsFontWithSize:_style.fontSize]
                                                                                   style:kMTLineStyleDisplay];
                realDisplayList.textColor = _style.textColor;
                [displayLists addObject:realDisplayList];
            }
        } @catch (NSException *exception) {
            // 兼容旧行为：拆分过程中若异常（越界等），退化为单行渲染
            [displayLists removeAllObjects];
            [displayLists addObject:_displayList];
        }
    }

    NSMutableArray<NSNumber *> *lineHeights = [NSMutableArray new];
    CGFloat totalHeight = 0;
    for (MTMathListDisplay *displayList in displayLists) {
        const CGFloat lineHeight = [self lineHeightForDisplayList:displayList];
        [lineHeights addObject:@(lineHeight)];
        totalHeight += lineHeight;
    }

    _wrappedDisplayLists = [displayLists copy];
    _wrappedLineHeights = [lineHeights copy];
    _wrappedTotalHeight = totalHeight;
    self.image = nil;
}

- (instancetype)initWithText:(NSString *)text style:(AMMathStyle *)style {
    NSError *error = nil;
    NSMutableString *mathText = [text mutableCopy];
    if ([mathText hasPrefix:@"\\["]) {
        [mathText deleteCharactersInRange:NSMakeRange(0, 2)];
    }
    if ([mathText hasSuffix:@"\\]"]) {
        [mathText deleteCharactersInRange:NSMakeRange(mathText.length - 2, 2)];
    }
    MTMathList *mathList = [MTMathListBuilder buildFromString:mathText ?: @""
                                                        error:&error];
    if (error) {
        self = [super initWithData:nil ofType:nil];
        if (self) {
            self.text = text;
            self.error = error;
            AMLogDebug(@"math parse error: %@", error);
        }
        return self;
    }
    
    style = style ?: [AMMathStyle defaultBlockStyle];
    
    @try {
        MTMathListDisplay *displayList = [MTTypesetter createLineForMathList:mathList
                                                                        font:[[MTFontManager fontManager] xitsFontWithSize:style.fontSize]
                                                                       style:kMTLineStyleDisplay];
        displayList.textColor = style.textColor;
        
        const CGFloat contentHeight = displayList.ascent + displayList.descent;
        CGFloat totalHeight = style.height;
        if (totalHeight <= 0) {
            totalHeight = contentHeight;
        }
        
        self = [super initWithData:nil ofType:nil];
        if (self) {
            self.text = text;
            _mathList = mathList;
            _displayList = displayList;
            _style = style;
            
            self.bounds = CGRectMake(0, 0, displayList.width, totalHeight);
            
            CGRect rect = self.bounds;
            switch (style.verticalAlignment) {
                case UIControlContentVerticalAlignmentCenter: {
                    rect.origin.y = -displayList.descent;
                }
                    break;
                case UIControlContentVerticalAlignmentBottom: {
                    rect.origin.y = -rect.size.height;
                }
                    break;
                case UIControlContentVerticalAlignmentTop: {
                    rect.origin.y = 0;
                }
                    break;
                default:
                    break;
            }
            self.bounds = rect;
        }
        return self;
    } @catch (NSException *exception) {
        self = [super initWithData:nil ofType:nil];
        if (self) {
            self.text = text;
            self.error = [[NSError alloc] initWithDomain:@"MathDisplayError" code:404 userInfo:exception.userInfo];
            AMLogDebug(@"math display exception: %@,text = %@", exception, text);
        }
        return self;
    }
}

+ (NSArray<AMBlockMathAttachment *> *)constructorBlockMathAttachmentWithText:(NSString *)text style:(AMMathStyle *)style {
    NSError *error = nil;
    NSMutableString *mathText = [text mutableCopy];
    if ([mathText hasPrefix:@"\\["]) {
        [mathText deleteCharactersInRange:NSMakeRange(0, 2)];
    }
    if ([mathText hasSuffix:@"\\]"]) {
        [mathText deleteCharactersInRange:NSMakeRange(mathText.length - 2, 2)];
    }
    MTMathList *totalMathList = [MTMathListBuilder buildFromString:mathText ?: @""
                                                             error:&error];
    
    if (error) {
        AMBlockMathAttachment *attachment = [[self alloc] initWithText:text style:style];
        return @[attachment];
    }
    
    style = style ?: [AMMathStyle defaultBlockStyle];
    
    @try {
        MTMathListDisplay *totalDisplayList = [MTTypesetter createLineForMathList:totalMathList
                                                                             font:[[MTFontManager fontManager] xitsFontWithSize:style.fontSize]
                                                                            style:kMTLineStyleDisplay];
#if 0
        // 旧实现（已注释）：
        // 使用 `UIScreen.mainScreen.bounds.size.width - 65` 作为 maxWidth，在构造阶段提前拆分为多个 attachment。
        // 这里的 65 为写死值，在 iPad 分屏/旋转/不同容器宽度/不同左右边距等场景下容易产生错误拆分/裁剪。
        NSMutableArray<AMBlockMathAttachment *> *attachList = [NSMutableArray new];
        CGFloat maxWidth = [UIScreen mainScreen].bounds.size.width - 65;
        if (totalDisplayList.width <= maxWidth) {
            AMBlockMathAttachment *attachment = [[self alloc] initWithDisplayList:totalDisplayList style:style];
            return @[attachment];
        }
        NSArray<NSNumber *> *segIndexs = [self getSegIndexWithDispayList:totalDisplayList];
        NSUInteger start = 0;
        for (NSNumber *segIndex in segIndexs) {
            NSUInteger index = [segIndex unsignedIntegerValue];
            NSMutableArray<MTMathAtom *> *atoms = [NSMutableArray new];
            for (NSUInteger i = start; i < index; i++) {
                [atoms addObject:totalMathList.atoms[i]];
            }
            start = index;
            MTMathList *realMathList = [MTMathList mathListWithAtomsArray:atoms];
            MTMathListDisplay *realDisplayList = [MTTypesetter createLineForMathList:realMathList
                                                                                font:[[MTFontManager fontManager] xitsFontWithSize:style.fontSize]
                                                                               style:kMTLineStyleDisplay];
            AMBlockMathAttachment *attachment = [[self alloc] initWithDisplayList:realDisplayList style:style];
            [attachList addObject:attachment];
        }

        NSUInteger lastIndex = [segIndexs.lastObject unsignedIntValue];
        if (lastIndex < totalMathList.atoms.count) {
            NSMutableArray<MTMathAtom *> *atoms = [NSMutableArray new];
            for (NSUInteger i = lastIndex; i < totalMathList.atoms.count; i++) {
                [atoms addObject:totalMathList.atoms[i]];
            }
            MTMathList *realMathList = [MTMathList mathListWithAtomsArray:atoms];
            MTMathListDisplay *realDisplayList = [MTTypesetter createLineForMathList:realMathList
                                                                                font:[[MTFontManager fontManager] xitsFontWithSize:style.fontSize]
                                                                               style:kMTLineStyleDisplay];
            AMBlockMathAttachment *attachment = [[self alloc] initWithDisplayList:realDisplayList style:style];
            [attachList addObject:attachment];
        }
        return [attachList copy];
#endif

        // 新实现：
        // 构造阶段不使用屏幕宽度推断 maxWidth；在 `attachmentBoundsForTextContainer:proposedLineFragment:`
        // 中基于真实的 `proposedLineFragment/NSTextContainer` 宽度动态计算是否需要换行与高度。
        AMBlockMathAttachment *attachment = [[self alloc] initWithDisplayList:totalDisplayList style:style];
        attachment.text = text;
        attachment->_mathList = totalMathList;
        return attachment ? @[attachment] : @[];
        
    } @catch (NSException *exception) {
        AMBlockMathAttachment *attachment = [[self alloc] initWithText:text style:style];
        return @[attachment];
    }
}

+ (NSArray<NSNumber *> *)getSegIndexWithDispayList:(MTMathListDisplay *)displayList maxWidth:(CGFloat)maxWidth {
    NSMutableArray<NSNumber *> *segIndexs = [NSMutableArray new];
    // 旧实现（已注释）：CGFloat maxWidth = [UIScreen mainScreen].bounds.size.width - 65;
    if (!displayList || maxWidth <= 0) {
        return @[];
    }
    CGFloat threshold = maxWidth;
    MTDisplay *preDisplay = nil;
    for (NSUInteger i = 0; i < displayList.subDisplays.count; i++) {
        MTDisplay *display = displayList.subDisplays[i];
        CGFloat currentDisplayEndPositionX = display.position.x + display.width;
        if (currentDisplayEndPositionX >= threshold) {
            // 旧逻辑使用 preDisplay 作为断点（当前 display 已超出阈值，取前一个 display 的末尾作为切分点）
            const NSUInteger segIndex = preDisplay.range.location + preDisplay.range.length;
            const NSUInteger lastSegIndex = segIndexs.lastObject.unsignedIntegerValue;
            if (segIndex > 0 && segIndex > lastSegIndex) {
                [segIndexs addObject:@(segIndex)];
            }
            // 下一行阈值应为 “上一阈值 + maxWidth”，而非成倍增长
            threshold += maxWidth;
        }
        // `range.location` 可能为 0（例如首个 atom），这里应判断 range 是否有效，避免 preDisplay 为空导致 segIndex=0。
        if (display.range.length != 0) {
            preDisplay = display;
        }
    }
    return [segIndexs copy];
}

- (void)drawImage:(CGSize)size {
    
    // 绘制图片使用新的API，防止size=0 Crash，并且部分场景复用绘制失败（首次绘制宽度为0）
    NSArray<MTMathListDisplay *> *displayLists = _wrappedDisplayLists.count > 0 ? _wrappedDisplayLists : (_displayList ? @[_displayList] : @[]);
    NSArray<NSNumber *> *lineHeights = _wrappedLineHeights;
    if (displayLists.count == 0) {
        return;
    }
    if (lineHeights.count != displayLists.count) {
        NSMutableArray<NSNumber *> *tmp = [NSMutableArray new];
        for (MTMathListDisplay *dl in displayLists) {
            [tmp addObject:@([self lineHeightForDisplayList:dl])];
        }
        lineHeights = [tmp copy];
    }
    if (size.width <= 0 || size.height <= 0) {
        return;
    }

    UIGraphicsImageRenderer *re = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    self.image = [re imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull rendererContext) {
        CGContextRef context = rendererContext.CGContext;

        CGContextTranslateCTM(context, 0, size.height);
        CGContextScaleCTM(context, 1.0, -1.0);

        CGFloat currentTop = size.height;
        for (NSUInteger i = 0; i < displayLists.count; i++) {
            MTMathListDisplay *displayList = displayLists[i];
            const CGFloat lineHeight = lineHeights[i].doubleValue;
            currentTop -= lineHeight;

            const CGFloat contentHeight = displayList.ascent + displayList.descent;

            CGFloat x = 0;
            switch (_style.horizontalAlignment) {
                case UIControlContentHorizontalAlignmentCenter:
                    x = (size.width - displayList.width) / 2;
                    break;
                case UIControlContentHorizontalAlignmentRight:
                    x = size.width - displayList.width;
                    break;
                case UIControlContentHorizontalAlignmentLeft:
                    x = 0;
                    break;
                default:
                    break;
            }
            const CGFloat y = currentTop + (lineHeight - contentHeight) / 2 + displayList.descent;
            displayList.position = CGPointMake(x, y);
            [displayList draw:context];
        }
    }];
}

- (UIImage *)imageForBounds:(CGRect)imageBounds
              textContainer:(NSTextContainer *)textContainer
             characterIndex:(NSUInteger)charIndex {
    const CGFloat width = floor(imageBounds.size.width);
    const CGFloat height = ceil(imageBounds.size.height);
    [self updateWrappedDisplayListsIfNeededForMaxWidth:width];
    if (!self.image || floor(self.image.size.width) != width || ceil(self.image.size.height) != height) {
        [self drawImage:CGSizeMake(width, height)];
    }
    return self.image;
}

- (CGRect)attachmentBoundsForTextContainer:(NSTextContainer *)textContainer
                      proposedLineFragment:(CGRect)lineFrag
                             glyphPosition:(CGPoint)position
                            characterIndex:(NSUInteger)charIndex {
    CGRect rect = [super attachmentBoundsForTextContainer:textContainer
                                     proposedLineFragment:lineFrag
                                            glyphPosition:position
                                           characterIndex:charIndex];

    // 使用文本布局上下文的真实宽度（参考 AMImageTextAttachment 的计算方式），避免使用屏幕宽度减 magic number。
    const CGFloat maxWidth = MAX(0, lineFrag.size.width - textContainer.lineFragmentPadding * 2);
    [self updateWrappedDisplayListsIfNeededForMaxWidth:maxWidth];
    if (_wrappedTotalHeight > 0) {
        rect.size.height = _wrappedTotalHeight;
    }
    rect.size.width = floor(maxWidth);
    
    CGFloat yPos = MAX(0, rect.origin.y);
    rect = CGRectMake(rect.origin.x, yPos, floor(rect.size.width), rect.size.height);

    if ([NSThread isMainThread]) {
        const CGFloat width = floor(rect.size.width);
        const CGFloat height = ceil(rect.size.height);
        if (!self.image || floor(self.image.size.width) != width || ceil(self.image.size.height) != height) {
            [self drawImage:CGSizeMake(width, height)];
        }
    }
    
    return rect;
}

- (NSAttributedString *)attributedString
{
    if (self.error) {
        return [[NSAttributedString alloc] initWithString:self.text ?: @"" attributes:@{
            NSForegroundColorAttributeName: _style.textColor ?: [UIColor blackColor],
            NSFontAttributeName: _style.font ?: [UIFont systemFontOfSize:UIFont.systemFontSize],
        }];
    }
    return [NSAttributedString attributedStringWithAttachment:self];
}

@end

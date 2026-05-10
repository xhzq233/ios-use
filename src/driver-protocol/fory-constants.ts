// ElementType: inverse of XCUIElement.ElementType
// Maps rawValue (Int32) to human-readable name
export const ELEMENT_TYPE_NAME: Record<number, string> = {
  0: 'Any',
  1: 'Other',
  2: 'Application',
  3: 'Group',
  4: 'Window',
  5: 'Sheet',
  6: 'Alert',
  7: 'Button',
  8: 'Cell',
  9: 'StaticText',
  10: 'TextField',
  11: 'SecureTextField',
  12: 'TextView',
  13: 'SearchField',
  14: 'Image',
  15: 'Icon',
  16: 'Link',
  17: 'Switch',
  18: 'Slider',
  19: 'TabBar',
  20: 'Tab',
  21: 'Toolbar',
  22: 'NavigationBar',
  23: 'Table',
  24: 'TableRow',
  25: 'TableColumn',
  26: 'CollectionView',
  27: 'ScrollView',
  28: 'WebView',
  29: 'Picker',
  30: 'PickerWheel',
  31: 'SegmentedControl',
  32: 'DatePicker',
  33: 'PageIndicator',
  34: 'ProgressIndicator',
  35: 'ActivityIndicator',
  36: 'Stepper',
  37: 'Menu',
};

export function elementTypeName(raw: number): string {
  return ELEMENT_TYPE_NAME[raw] ?? 'Other';
}

// SwipeDirection
export const SWIPE_DIR_FORTH = 0;
export const SWIPE_DIR_BACK = 1;

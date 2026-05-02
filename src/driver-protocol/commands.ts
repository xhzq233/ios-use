export const DRIVER_COMMANDS = {
  CREATE_SESSION: 'createSession',
  DELETE_SESSION: 'deleteSession',
  DOM: 'dom',
  FIND: 'find',
  TAP: 'tap',
  LONG_PRESS: 'longPress',
  INPUT: 'input',
  SWIPE: 'swipe',
  WAIT_FOR: 'waitFor',
  ACTIVATE_APP: 'activateApp',
  TERMINATE_APP: 'terminateApp',
  SCREENSHOT: 'screenshot',
  OSLOG: 'oslog',
} as const;

export type DriverCommand = typeof DRIVER_COMMANDS[keyof typeof DRIVER_COMMANDS];

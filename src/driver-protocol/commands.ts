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
  OPEN_URL: 'openURL',
  PROBE_FETCH: 'probeFetch',
  PROXY_CA_PUSH: 'proxyCAPush',
  DISMISS_ALERT: 'dismissAlert',
  SCREENSHOT: 'screenshot',
} as const;

export type DriverCommand = typeof DRIVER_COMMANDS[keyof typeof DRIVER_COMMANDS];

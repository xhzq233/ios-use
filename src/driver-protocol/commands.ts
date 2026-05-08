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
  PROXY_START: 'proxyStart',
  PROXY_STOP: 'proxyStop',
  PROXY_INGRESS_START: 'proxyIngressStart',
  PROXY_INGRESS_STOP: 'proxyIngressStop',
  PROXY_PUSH_PROFILE: 'proxyPushProfile',
  SCREENSHOT: 'screenshot',
  OSLOG: 'oslog',
} as const;

export type DriverCommand = typeof DRIVER_COMMANDS[keyof typeof DRIVER_COMMANDS];

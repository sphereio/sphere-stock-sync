{ExtendedLogger, ProjectCredentialsConfig} = require 'sphere-node-utils'
MarketPlaceStockUpdater = require '../lib/marketplace-stock-updater'
package_json = require '../package.json'
Config = require '../config'

argv = require('optimist')
  .usage('Usage: $0 --projectKey key --clientId id --clientSecret secret --logDir dir --logLevel level --timeout timeout')
  .describe('projectKey', 'your SPHERE.IO project-key')
  .describe('clientId', 'your SPHERE.IO OAuth client id')
  .describe('clientSecret', 'your SPHERE.IO OAuth client secret')
  .describe('fetchHours', 'how many hours of modification should be fetched')
  .describe('timeout', 'timeout for requests')
  .describe('sphereHost', 'SPHERE.IO API host to connecto to')
  .describe('logLevel', 'log level for file logging')
  .describe('logDir', 'directory to store logs')
  .describe('logSilent', 'use console to print messages')
  .default('fetchHours', 24)
  .default('timeout', 60000)
  .default('logLevel', 'info')
  .default('logDir', '.')
  .default('logSilent', false)
  .demand(['projectKey'])
  .argv

logOptions =
  name: "#{package_json.name}-#{package_json.version}"
  streams: [
    { level: 'error', stream: process.stderr }
    { level: argv.logLevel, path: "#{argv.logDir}/sphere-stock-sync.log" }
  ]
logOptions.silent = argv.logSilent if argv.logSilent
logger = new ExtendedLogger
  additionalFields:
    project_key: argv.projectKey
  logConfig: logOptions
if argv.logSilent
  logger.bunyanLogger.trace = -> # noop
  logger.bunyanLogger.debug = -> # noop

process.on 'SIGUSR2', -> logger.reopenFileStreams()
process.on 'exit', => process.exit(@exitCode)

ProjectCredentialsConfig.create()
.then (credentials) =>
  options =
    baseConfig:
      fetchHours: argv.fetchHours
      timeout: argv.timeout
      user_agent: "#{package_json.name} - #{package_json.version}"
    master: credentials.enrichCredentials
      project_key: Config.config.project_key
      client_id: Config.config.client_id
      client_secret: Config.config.client_secret
    retailer: credentials.enrichCredentials
      project_key: argv.projectKey
      client_id: argv.clientId
      client_secret: argv.clientSecret

  options.baseConfig.host = argv.sphereHost if argv.sphereHost?

  updater = new MarketPlaceStockUpdater logger, options
  updater.run()
  .then (msg) =>
    logger.info msg
    @exitCode = 0
  .catch (error) =>
    logger.error error, 'Oops, something went wrong!'
    @exitCode = 1
  .done()
.catch (err) =>
  logger.error err, 'Problems on getting client credentials from config files.'
  @exitCode = 1
.done()
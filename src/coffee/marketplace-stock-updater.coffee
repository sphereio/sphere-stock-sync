Q = require 'q'
_ = require 'underscore'
SphereClient = require 'sphere-node-client'
{InventorySync} = require 'sphere-node-sync'
{Qutils} = require 'sphere-node-utils'

CHANNEL_REF_NAME = 'supplyChannel'
CHANNEL_ROLES = ['InventorySupply', 'OrderExport', 'OrderImport']

class MarketPlaceStockUpdater

  constructor: (@logger, options = {}) ->
    throw new Error 'No base configuration in options!' unless options.baseConfig
    throw new Error 'No master configuration in options!' unless options.master
    throw new Error 'No retailer configuration in options!' unless options.retailer

    masterOpts = _.clone options.baseConfig
    masterOpts.config = options.master

    retailerOpts = _.clone options.baseConfig
    retailerOpts.config = options.retailer

    @inventorySync = new InventorySync masterOpts
    @masterClient = @inventorySync._client # share client instance to have only one TaskQueue
    @retailerClient = new SphereClient retailerOpts

    @retailerProjectKey = options.retailer.project_key
    @fetchHours = options.baseConfig.fetchHours or 24
    @_resetSummary()

  _resetSummary: ->
    @summary =
      toUpdate: 0
      toCreate: 0
      synced: 0
      failed: 0

  run: (callback) ->
    @_resetSummary()

    # process products in retailer
    @masterClient.channels.ensure(@retailerProjectKey, CHANNEL_ROLES)
    .then (result) =>
      retailerChannel = result.body

      # fetch inventories from last X hours
      @retailerClient.inventoryEntries.last("#{@fetchHours}h").all().process (payload) =>
        retailerInventoryEntries = payload.body.results
        @logger?.debug retailerInventoryEntries, 'About to processing following retailer inventory entries'

        Qutils.processList retailerInventoryEntries, (ieChunk) =>
          # fetch corresponding products for sku mapping
          retailerProducts = @retailerClient.productProjections.staged(true).all().whereOperator('or')
          _.each ieChunk, (stock) ->
            retailerProducts.where("masterVariant(sku = \"#{stock.sku}\") or variants(sku = \"#{stock.sku}\")")
          retailerProducts.fetch()
          .then (result) =>
            matchedRetailerProductsBySku = result.body.results
            @logger?.debug matchedRetailerProductsBySku, 'Matched retailer products by sku'
            # create sku mapping (attribute -> sku)
            mapping = @_createSkuMap(matchedRetailerProductsBySku)
            @logger?.debug mapping, "Mapped #{_.size mapping} SKUs for retailer products"

            # enhance inventory entries with channel (from master)
            enhancedRetailerInventoryEntries = @_enhanceWithRetailerChannel ieChunk, retailerChannel.id
            @logger?.debug enhancedRetailerInventoryEntries, "Enhanced inventory entries witch retailer channel #{retailerChannel.id}"

            # map inventory entries by replacing SKUs with the masterSKU (found in variant attributes of retailer products)
            # this way we can then query those inventories from master and decide whether to update or create them
            mappedInventoryEntries = @_replaceSKUs enhancedRetailerInventoryEntries, mapping
            @logger?.debug mappedInventoryEntries, "#{_.size mappedInventoryEntries} inventory entries are ready to be processed"
            # IMPORTANT: since some inventories may not be mapped to a masterSku
            # we should simply discard them since they do not need to be sync to master
            mappendInventoryEntriesWithMasterSkuOnly = _.filter mappedInventoryEntries, (e) -> e.sku
            return Q() if _.size(mappendInventoryEntriesWithMasterSkuOnly) is 0

            ieMaster = @masterClient.inventoryEntries.all().whereOperator('or')
            _.each mappendInventoryEntriesWithMasterSkuOnly, (entry) ->
              ieMaster.where("sku = \"#{entry.sku}\"")
            ieMaster.fetch()
            .then (result) =>
              existingEntriesInMaster = result.body.results
              @logger?.debug existingEntriesInMaster, "Found #{_.size existingEntriesInMaster} matching inventory entries in master"

              Q.allSettled _.map mappendInventoryEntriesWithMasterSkuOnly, (retailerEntry) =>
                masterEntry = _.find existingEntriesInMaster, (e) -> e.sku is retailerEntry.sku
                if masterEntry?
                  @logger?.debug masterEntry, "Found existing inventory entry in master for sku #{retailerEntry.sku}, about to build update actions"
                  sync = @inventorySync.buildActions(retailerEntry, masterEntry)
                  if sync.get()
                    @summary.toUpdate++
                    sync.update()
                  else
                    @logger?.debug masterEntry, "No update necessary for entry in master with sku #{retailerEntry.sku}"
                    Q()
                else
                  @logger?.debug "No inventory entry found in master for sku #{retailerEntry.sku}, about to create it"
                  @summary.toCreate++
                  @masterClient.inventoryEntries.save(retailerEntry)
              .then (results) =>
                failures = []
                _.each results, (result) =>
                  if result.state is 'fulfilled'
                    @summary.synced++
                  else
                    @summary.failed++
                    failures.push result.reason
                if _.size(failures) > 0
                  @logger?.error failures, 'Errors while syncing stock'
                Q()
        , {accumulate: false, maxParallel: 10}
      , {accumulate: false}
    .then =>
      if @summary.toUpdate is 0 and @summary.toCreate is 0
        message = 'Summary: 0 unsynced stocks, everything is fine'
      else
        message = "Summary: there were #{@summary.toUpdate + @summary.toCreate} unsynced stocks, " +
          "(#{@summary.toUpdate} were updates and #{@summary.toCreate} were new) and " +
          "#{@summary.synced} were successfully synced (#{@summary.failed} failed)"
      Q message

  _enhanceWithRetailerChannel: (inventoryEntries, channelId) ->
    _.map inventoryEntries, (entry) ->
      entry.supplyChannel =
        typeId: 'channel'
        id: channelId
      entry

  _replaceSKUs: (inventoryEntries, retailerSku2masterSku) ->
    _.map inventoryEntries, (entry) ->
      entry.sku = retailerSku2masterSku[entry.sku]
      entry

  _createSkuMap: (products) ->
    retailerSku2masterSku = {}
    _.each products, (product) =>
      product.variants or= []
      variants = [product.masterVariant].concat(product.variants)
      _.each variants, (variant) =>
        r2m = @_matchVariant(variant)
        _.extend(retailerSku2masterSku, r2m)

    retailerSku2masterSku

  _matchVariant: (variant) ->
    retailerSku = variant.sku
    return {} unless retailerSku
    return {} unless variant.attributes
    attribute = _.find variant.attributes, (attribute) ->
      attribute.name is 'mastersku'
    return {} unless attribute
    masterSku = attribute.value
    return {} unless masterSku
    r2m = {}
    r2m[retailerSku] = masterSku

    r2m

module.exports = MarketPlaceStockUpdater

# This file constructs VimFx’s options UI in the Add-ons Manager.

defaults = require('./defaults')
prefs = require('./prefs')
prefsBulk = require('./prefs-bulk')
translate = require('./translate')
utils = require('./utils')

TYPE_MAP = {
  string: 'string'
  number: 'integer'
  boolean: 'bool'
}

observe = (options) ->
  observer = new Observer(options)
  utils.observe('vimfx-options-displayed', observer)
  utils.observe('vimfx-options-hidden',    observer)
  module.onShutdown(->
    observer.destroy()
  )

# Generalized observer.
class BaseObserver
  constructor: (@options) ->
    @document = null
    @container = null
    @listeners = []

  useCapture: true

  listen: (element, event, action) ->
    element.addEventListener(event, action, @useCapture)
    @listeners.push([element, event, action, @useCapture])

  unlisten: ->
    for [element, event, action, useCapture] in @listeners
      element.removeEventListener(event, action, useCapture)
    @listeners.length = 0

  type: (value) -> TYPE_MAP[typeof value]

  injectSettings: ->

  appendSetting: (attributes) ->
    outer = @document.createElement('div')
    outer.classList.add('setting')
    outer.classList.add('first-row') if attributes['first-row']
    outer.classList.add(attributes.class)
    outer.setAttribute('data-pref', attributes.pref)
    outer.setAttribute('data-type', attributes.type)
    label = @document.createElement('label')
    title = @document.createElement('span')
    title.className = 'title'
    title.innerText = attributes.title
    label.appendChild(title)
    help = @document.createElement('span')
    help.className = 'desc'
    help.innerText = attributes.desc or ''
    input = @document.createElement('input')
    _this = this
    switch attributes.type
      when 'bool'
        input.type = 'checkbox'
        input.checked = prefs.root.get(attributes.pref)
        input.addEventListener('change', ->
          prefs.root.set(attributes.pref, input.checked)
        )
        prefobserver = prefs.root.observe(attributes.pref, ->
          input.checked = prefs.root.get(attributes.pref)
        )
        @document.defaultView.addEventListener('unload', ->
          prefs?.root.unobserve(attributes.pref, prefobserver)
        )
      when 'integer'
        input.type = 'number'
        input.value = prefs.root.get(attributes.pref)
        input.addEventListener('input', ->
          prefs.root.set(attributes.pref, parseInt(input.value, 10))
        )
        prefobserver = prefs.root.observe(attributes.pref, ->
          input.value = prefs.root.get(attributes.pref)
        )
        @document.defaultView.addEventListener('unload', ->
          prefs?.root.unobserve(attributes.pref, prefobserver)
        )
      when 'string'
        input.type = 'text'
        input.value = prefs.root.get(attributes.pref)
        input.addEventListener('input', ->
          prefs.root.set(attributes.pref, input.value)
          if outer.classList.contains('is-shortcut')
            _this.refreshShortcutErrors()
        )
        prefobserver = prefs.root.observe(attributes.pref, ->
          input.value = prefs.root.get(attributes.pref)
        )
        @document.defaultView.addEventListener('unload', ->
          prefs?.root.unobserve(attributes.pref, prefobserver)
        )
      when 'control' # injectHeader special case
        control = @document.createElement('span')
        control.className = 'control'
        # can't use <label> when control has multiple buttons:
        label = @document.createElement('span')
        label.appendChild(title)
        label.appendChild(control)
    label.appendChild(input) if attributes.pref # some nodes are just headlines
    outer.appendChild(label)
    outer.appendChild(help) # needed even if empty, as validator puts error here
    @container.appendChild(outer)
    return outer

  observe: (@document, topic, addonId) ->
    switch topic
      when 'vimfx-options-displayed'
        @init()
      when 'vimfx-options-hidden'
        @destroy()

  init: ->
    @container = @document.getElementById('detail-rows')
    @injectSettings()

  destroy: ->
    @unlisten()

# VimFx specific observer.
class Observer extends BaseObserver
  constructor: (@vimfx) ->
    super({id: @vimfx.id})

  injectSettings: ->
    @injectHeader()
    @injectOptions()
    @injectShortcuts()
    @setupKeybindings()

    if @vimfx.goToCommand
      utils.nextTick(@document.ownerGlobal, =>
        {pref} = @vimfx.goToCommand
        setting = @container.querySelector("[data-pref='#{pref}']")
        setting.scrollIntoView()
        setting.querySelector('input').select()
        @vimfx.goToCommand = null
      )

  injectHeader: ->
    setting = @appendSetting({
      type: 'control'
      title: translate('prefs.instructions.title')
      desc: translate(
        'prefs.instructions.desc',
        @vimfx.options['options.key.quote'],
        @vimfx.options['options.key.insert_default'],
        @vimfx.options['options.key.reset_default'],
        '<c-z>'
      )
      'first-row': 'true'
    })
    setting.id = 'header'

    href = "#{@vimfx.info.homepageURL}/tree/master/documentation#contents"
    docsLink = @document.createElement('a')
    docsLink.innerText = translate('prefs.documentation')
    utils.setAttributes(docsLink, {
      href
      target: '_blank'
    })
    setting.querySelector('.control').appendChild(docsLink)

    for key, fn of BUTTONS
      button = @document.createElement('button')
      button.innerText = translate("prefs.#{key}.label")
      button.onclick = runWithVim.bind(null, @vimfx, fn)
      setting.querySelector('.control').appendChild(button)

    return

  injectOptions: ->
    for key, value of defaults.options
      @appendSetting({
        pref: "#{defaults.BRANCH}#{key}"
        type: @type(value)
        title: translate("pref.#{key}.title")
        desc: translate("pref.#{key}.desc")
      })
    return

  injectShortcuts: ->
    for mode in @vimfx.getGroupedCommands()
      @appendSetting({
        type: 'control'
        title: mode.name
        'first-row': 'true'
      })

      for category in mode.categories
        if category.name
          @appendSetting({
            type: 'control'
            title: category.name
            'first-row': 'true'
          })

        for {command} in category.commands
          @appendSetting({
            pref: command.pref
            type: 'string'
            title: command.description
            desc: @generateErrorMessage(command.pref)
            class: 'is-shortcut'
          })

    return

  generateErrorMessage: (pref) ->
    commandErrors = @vimfx.errors[pref] ? []
    return commandErrors.map(({id, context, subject}) ->
      return translate("error.#{id}", context ? subject, subject)
    ).join('\n')

  setupKeybindings: ->
    # Note that `setting = event.originalTarget` does _not_ return the correct
    # element in these listeners!
    quote = false
    @listen(@container, 'keydown', (event) =>
      input = event.target
      isString = (input.type == 'text')

      setting = input.closest('.setting')
      pref = setting.getAttribute('data-pref')
      keyString = @vimfx.stringifyKeyEvent(event)

      # Some shortcuts only make sense for string settings. We still match
      # those shortcuts and suppress the default behavior for _all_ types of
      # settings for consistency. For example, pressing <c-d> in a number input
      # (which looks like a text input) would otherwise bookmark the page, and
      # <c-q> would close the window!
      switch
        when not keyString
          return
        when quote
          break unless isString
          utils.insertText(input, keyString)
          prefs.root.set(pref, input.value)
          quote = false
        when keyString == @vimfx.options['options.key.quote']
          break unless isString
          quote = true
          # Override `<force>` commands (such as `<escape>` and `<tab>`).
          return unless vim = @vimfx.getCurrentVim(utils.getCurrentWindow())
          @vimfx.modes.normal.commands.quote.run({vim, count: 1})
        when keyString == @vimfx.options['options.key.insert_default']
          break unless isString
          utils.insertText(input, prefs.root.default.get(pref))
          prefs.root.set(pref, input.value)
        when keyString == @vimfx.options['options.key.reset_default']
          prefs.root.set(pref, null)
        else
          return

      event.preventDefault()
      @refreshShortcutErrors()
    )
    @listen(@container, 'blur', -> quote = false)

  refreshShortcutErrors: ->
    for setting in @container.getElementsByClassName('is-shortcut')
      setting.querySelector('.desc').innerText =
        @generateErrorMessage(setting.getAttribute('data-pref'))
    return

resetAllPrefs = (vim) ->
  vim._modal('confirm', [translate('prefs.reset.enter')], (ok) ->
    return unless ok
    prefsBulk.resetAll()
    vim.notify(translate('prefs.reset.success'))
  )

exportAllPrefs = (vim) ->
  exported = prefsBulk.exportAll()
  if Object.keys(exported).length == 0
    vim.notify(translate('prefs.export.none'))
  else
    utils.writeToClipboard(JSON.stringify(exported, null, 2))
    vim.notify(translate('prefs.export.success'))

importExportedPrefs = (vim) ->
  vim._modal('prompt', [translate('prefs.import.enter')], (input) ->
    return if input == null or input.trim() == ''
    result = prefsBulk.importExported(input.trim())
    if result.errors.length == 0
      vim.notify(translate('prefs.import.success'))
    else
      vim._modal('alert', [prefsBulk.createImportErrorReport(result)])
  )

runWithVim = (vimfx, fn) ->
  return unless vim = vimfx.getCurrentVim(utils.getCurrentWindow())
  fn(vim)

BUTTONS = {
  export: exportAllPrefs
  import: importExportedPrefs
  reset: resetAllPrefs
}

module.exports = {
  observe
}

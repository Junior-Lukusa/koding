class EnvironmentScene extends KDDiaScene

  constructor:->
    super
      cssClass  : 'environments-scene'
      lineWidth : 1

  whenItemsLoadedFor:do->
    # poor man's when/promise implementation ~ GG
    (containers, callback)->
      counter = containers.length
      containers.forEach (container)->
        container.once "DataLoaded", ->
          if counter is 1 then do callback
          counter--

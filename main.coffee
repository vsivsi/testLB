lbJobs = new JobCollection 'lbJobs'

if Meteor.isClient

  Template.dataTable.helpers

    dataEntries: () ->
      return lbJobs.find { type: @worker }, { sort: { "result.timestamp": -1 }, limit: 5 }

    timeStamp: () ->
      moment(this.result.timestamp).format("dddd, MMMM Do YYYY, h:mm:ss a")

  Meteor.startup () ->

    timeLimit = (min) ->
      tl = new Date()
      tl.setMinutes(tl.getMinutes() - min)
      tl

    # Meteor.subscribe 'sortedJobs', timeLimit(15), () ->

    Tracker.autorun () ->

      Meteor.subscribe 'sortedJobs', timeLimit(30)

      data1 = ['data1']
      x1 = ['x1']
      chartData = lbJobs.find({ type: 'getData' }, { sort: { "result.timestamp": 1 } })
        .forEach (d) ->
          data1.push d.result.percent
          x1.push d.result.timestamp

      data2 = ['data2']
      x2 = ['x2']
      chartData = lbJobs.find({ type: 'getData2' }, { sort: { "result.timestamp": 1 } })
        .forEach (d) ->
          data2.push d.result.percent
          x2.push d.result.timestamp

      lineChart = window.c3.generate(
        bindto: '#chart'
        data:
          columns: [
            x1
            data1
            x2
            data2
          ]
          xs:
            data1: "x1"
            data2: "x2"
          names:
            data1: "Temperature"
            data2: "Light"
        axis:
          y:
            min: 0
            max: 100
            padding:
              top: 0
              bottom: 0
            label:
              text: 'Percent'
              position: 'outer-middle'
          x:
            label:
              text: 'Time'
              position: 'outer-center'
            type: 'timeseries',
            tick:
              fit: false
              format: '%H:%M'
      )

##################################################################################################

if Meteor.isServer

  lbJobs._ensureIndex { "result.timestamp": 1 }

  Meteor.publish 'sortedJobs', (timeLimit) ->
    return lbJobs.find { status: 'completed', updated: { $gt: timeLimit } }, { sort: { "result.timestamp": -1 } }

  request = Meteor.npmRequire 'request'
  es = Meteor.npmRequire 'event-stream'

  Meteor.startup () ->

    lbJobs.promote 1000

    lbJobs.setLogStream process.stdout

    job = new Job(lbJobs, 'getData',
      dev: process.env["LITTLEBIT_DEV1_ID"]
    )
    .retry({ retries: 8, wait: 1000, backoff: 'exponential' })
    .repeat({ wait: 40*1000 })
    .save({cancelRepeats: true})

    job2 = new Job(lbJobs, 'getData2',
      dev: process.env["LITTLEBIT_DEV2_ID"]
    )
    .retry({ retries: 8, wait: 1000, backoff: 'exponential' })
    .repeat({ wait: 20*1000 })
    .save({cancelRepeats: true})

    # code to run on server at startup

    lbJobs.startJobServer()

    q = lbJobs.processJobs ['getData','getData2'], { pollInterval: 500000000 }, (j, cb) ->

      bind_env = (func) ->
        if func?
           return Meteor.bindEnvironment func, (err) -> throw err
        else
           return func

      finishJob = bind_env (err, val) ->
        if err
          j.fail { error: "#{err}" }
        else
          j.done val
        cb()

      authToken = process.env["LITTLEBIT_AUTH_TOKEN"]
      deviceId = j.data.dev

      reqOptions =
        url: "https://api-http.littlebitscloud.cc/v3/devices/#{deviceId}/input"
        headers:
          "Authorization": "Bearer #{authToken}"

      reqStream = request(reqOptions)
      reqStream.on('error', (err) ->
            console.error "Error: ", err
            finishJob err
            reqStream.abort()
         )
         .on('response', (res) ->
            if res.statusCode isnt 200
              console.warn "Response status:", res.statusCode
              finishJob new Error "Bad HTTP response (#{res.statusCode})"
              reqStream.abort()
         )
         .pipe(es.split())
         .pipe(es.map (data, cb)->
            if data
               cb(null, data.substr(5))
            else
               cb()
         )
         .pipe(es.parse())
         .pipe(es.map (data, cb)->
            if data and data.percent?
              cb(null, "#{data.percent}%\n")
              finishJob null, { timestamp: data.timestamp, percent: data.percent }
            else
              finishJob new Error "Missing data value"
              cb()
            reqStream.abort()
         )
         # .pipe(process.stdout)

    lbJobs.find({ status: 'ready' })
      .observe({ added: () -> q.trigger() })

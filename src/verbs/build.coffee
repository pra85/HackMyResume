###*
Implementation of the 'build' verb for HackMyResume.
@module verbs/build
@license MIT. See LICENSE.md for details.
###



_              = require('underscore')
PATH           = require('path')
FS             = require('fs')
MD             = require('marked')
MKDIRP         = require('mkdirp')
extend         = require('extend')
parsePath      = require('parse-filepath')
RConverter     = require('fresh-jrs-converter')
HMSTATUS       = require('../core/status-codes')
HMEVENT        = require('../core/event-codes')
RTYPES         =
  FRESH: require('../core/fresh-resume')
  JRS: require('../core/jrs-resume')
_opts          = require('../core/default-options')
FRESHTheme     = require('../core/fresh-theme')
JRSTheme       = require('../core/jrs-theme')
ResumeFactory  = require('../core/resume-factory')
_fmts          = require('../core/default-formats')
Verb           = require('../verbs/verb')

_err = null
_log = null
_rezObj = null
build = null
prep = null
single = null
verifyOutputs = null
addFreebieFormats = null
expand = null
verifyTheme = null
loadTheme = null

###* An invokable resume generation command. ###
BuildVerb = module.exports = Verb.extend

  ###* Create a new build verb. ###
  init: () -> @._super 'build'

  ###* Invoke the Build command. ###
  invoke: ->
    @stat HMEVENT.begin, { cmd: 'build' }
    ret = build.apply @, arguments
    @stat HMEVENT.end
    return ret



###*
Given a source resume in FRESH or JRS format, a destination resume path, and a
theme file, generate 0..N resumes in the desired formats.
@param src Path to the source JSON resume file: "rez/resume.json".
@param dst An array of paths to the target resume file(s).
@param theme Friendly name of the resume theme. Defaults to "modern".
@param logger Optional logging override.
###
build = ( src, dst, opts ) ->

  if !src || !src.length
    @err HMSTATUS.resumeNotFound, { quit: true }

  prep src, dst, opts

  # Load input resumes as JSON...
  sheetObjects = ResumeFactory.load(src, {
    format: null, objectify: false, quit: true, inner: { sort: _opts.sort }
  }, @);

  # Explicit check for any resume loading errors...
  if !sheetObjects || _.some( sheetObjects, (so) -> return so.fluenterror )
    return null

  sheets = sheetObjects.map((r) -> return r.json )

  # Load the theme...
  theme = null
  @stat HMEVENT.beforeTheme, { theme: _opts.theme }
  try
    tFolder = verifyTheme.call @, _opts.theme
    theme = _opts.themeObj = loadTheme tFolder
  catch ex
    newEx =
      fluenterror: HMSTATUS.themeLoad
      inner: ex
      attempted: _opts.theme
    this.err HMSTATUS.themeLoad, newEx
    return null

  @stat HMEVENT.afterTheme, { theme: theme }

  # Check for invalid outputs...
  inv = verifyOutputs.call @, dst, theme
  if inv && inv.length
    @err HMSTATUS.invalidFormat, { data: inv, theme: theme }

  ## Merge input resumes, yielding a single source resume.
  rez = null
  if sheets.length > 1
    isFRESH = !sheets[0].basics
    mixed = _.any sheets, (s) -> return if isFRESH then s.basics else !s.basics
    @stat HMEVENT.beforeMerge, { f: _.clone(sheetObjects), mixed: mixed }
    if mixed
      this.err HMSTATUS.mixedMerge

    rez = _.reduceRight sheets, ( a, b, idx ) ->
      extend( true, b, a )

    @stat HMEVENT.afterMerge, { r: rez }
  else
    rez = sheets[0];

  # Convert the merged source resume to the theme's format, if necessary
  orgFormat = if rez.basics then 'JRS' else 'FRESH';
  toFormat = if theme.render then 'JRS' else 'FRESH';
  if toFormat != orgFormat
    @stat HMEVENT.beforeInlineConvert
    rez = RConverter[ 'to' + toFormat ]( rez );
    @stat HMEVENT.afterInlineConvert, { file: sheetObjects[0].file, fmt: toFormat }

  # Add freebie formats to the theme
  addFreebieFormats theme
  @stat HMEVENT.applyTheme, { r: rez, theme: theme }

  # Load the resume into a FRESHResume or JRSResume object
  _rezObj = new (RTYPES[ toFormat ])().parseJSON( rez );

  # Expand output resumes...
  targets = expand( dst, theme );

  # Run the transformation!
  _.each targets, (t) ->
    t.final = single.call this, t, theme, targets
  , @

  # Don't send the client back empty-handed
  sheet: _rezObj
  targets: targets
  processed: targets



###*
Prepare for a BUILD run.
###
prep = ( src, dst, opts ) ->

  # Cherry-pick options //_opts = extend( true, _opts, opts );
  _opts.theme = (opts.theme && opts.theme.toLowerCase().trim()) || 'modern';
  _opts.prettify = opts.prettify is true
  _opts.css = opts.css
  _opts.pdf = opts.pdf
  _opts.wrap = opts.wrap || 60
  _opts.stitles = opts.sectionTitles
  _opts.tips = opts.tips
  _opts.errHandler = opts.errHandler
  _opts.noTips = opts.noTips
  _opts.debug = opts.debug
  _opts.sort = opts.sort

  # If two or more files are passed to the GENERATE command and the TO
  # keyword is omitted, the last file specifies the output file.
  ( src.length > 1 && ( !dst || !dst.length ) ) && dst.push( src.pop() )
  return



###*
Generate a single target resume such as "out/rez.html" or "out/rez.doc".
TODO: Refactor.
@param targInfo Information for the target resume.
@param theme A FRESHTheme or JRSTheme object.
###
single = ( targInfo, theme, finished ) ->

  ret = null
  ex = null
  f = targInfo.file

  try

    if !targInfo.fmt
      return
    fType = targInfo.fmt.outFormat
    fName = PATH.basename f, '.' + fType
    theFormat = null

    @.stat HMEVENT.beforeGenerate,
      fmt: targInfo.fmt.outFormat
      file: PATH.relative(process.cwd(), f)

    # If targInfo.fmt.files exists, this format is backed by a document.
    # Fluent/FRESH themes are handled here.
    if targInfo.fmt.files && targInfo.fmt.files.length
      theFormat = _fmts.filter(
        (fmt) -> return fmt.name == targInfo.fmt.outFormat )[0];
      MKDIRP.sync( PATH.dirname( f ) ); # Ensure dest folder exists;
      _opts.targets = finished;
      ret = theFormat.gen.generate( _rezObj, f, _opts );

    # Otherwise this is an ad-hoc format (JSON, YML, or PNG) that every theme
    # gets "for free".
    else
      theFormat = _fmts.filter( (fmt) ->
        return fmt.name == targInfo.fmt.outFormat
      )[0];
      outFolder = PATH.dirname f
      MKDIRP.sync( outFolder ); # Ensure dest folder exists;
      ret = theFormat.gen.generate( _rezObj, f, _opts );

  catch e
    # Catch any errors caused by generating this file and don't let them
    # propagate -- typically we want to continue processing other formats
    # even if this format failed.
    ex = e;

  this.stat HMEVENT.afterGenerate,
    fmt: targInfo.fmt.outFormat,
    file: PATH.relative( process.cwd(), f ),
    error: ex

  if ex
    if ex.fluenterror
      this.err( ex.fluenterror, ex );
    else
      this.err( HMSTATUS.generateError, { inner: ex } );

  return ret



###*
Ensure that user-specified outputs/targets are valid.
###
verifyOutputs = ( targets, theme ) ->
  @.stat HMEVENT.verifyOutputs, { targets: targets, theme: theme }
  _.reject targets.map( ( t ) ->
    pathInfo = parsePath t
    {
      format: pathInfo.extname.substr(1)
    }),
    (t) -> t.format == 'all' || theme.hasFormat( t.format )

###*
Reinforce the chosen theme with "freebie" formats provided by HackMyResume.
A "freebie" format is an output format such as JSON, YML, or PNG that can be
generated directly from the resume model or from one of the theme's declared
output formats. For example, the PNG format can be generated for any theme
that declares an HTML format; the theme doesn't have to provide an explicit
PNG template.
@param theTheme A FRESHTheme or JRSTheme object.
###
addFreebieFormats = ( theTheme ) ->
  # Add freebie formats (JSON, YAML, PNG) every theme gets...
  # Add HTML-driven PNG only if the theme has an HTML format.
  theTheme.formats.json = theTheme.formats.json || {
    freebie: true, title: 'json', outFormat: 'json', pre: 'json',
    ext: 'json', path: null, data: null
  }
  theTheme.formats.yml = theTheme.formats.yml || {
    freebie: true, title: 'yaml', outFormat: 'yml', pre: 'yml',
    ext: 'yml', path: null, data: null
  }
  if theTheme.formats.html && !theTheme.formats.png
    theTheme.formats.png = {
      freebie: true, title: 'png', outFormat: 'png',
      ext: 'yml', path: null, data: null
    }
  return



###*
Expand output files. For example, "foo.all" should be expanded to
["foo.html", "foo.doc", "foo.pdf", "etc"].
@param dst An array of output files as specified by the user.
@param theTheme A FRESHTheme or JRSTheme object.
###
expand = ( dst, theTheme ) ->

  # Set up the destination collection. It's either the array of files passed
  # by the user or 'out/resume.all' if no targets were specified.
  destColl = (dst && dst.length && dst) || [PATH.normalize('out/resume.all')];

  # Assemble an array of expanded target files... (can't use map() here)
  targets = [];
  destColl.forEach (t) ->
    to = PATH.resolve(t)
    pa = parsePath(to)
    fmat = pa.extname || '.all';
    targets.push.apply( targets,
      if fmat == '.all'
      then Object.keys( theTheme.formats ).map( ( k ) ->
        z = theTheme.formats[k]
        return { file: to.replace( /all$/g, z.outFormat ), fmt: z }
      )
      else [{ file: to, fmt: theTheme.getFormat( fmat.slice(1) ) }]
    )
  targets



###*
Verify the specified theme name/path.
###
verifyTheme = ( themeNameOrPath ) ->
  tFolder = PATH.join(
    parsePath( require.resolve('fresh-themes') ).dirname,
    '/themes/',
    themeNameOrPath
  )
  exists = require('path-exists').sync
  if !exists( tFolder )
    tFolder = PATH.resolve themeNameOrPath
    if !exists tFolder
      this.err HMSTATUS.themeNotFound, { data: _opts.theme }
  tFolder



###*
Load the specified theme, which could be either a FRESH theme or a JSON Resume
theme.
###
loadTheme = ( tFolder ) ->

  # Create a FRESH or JRS theme object
  theTheme =
    if _opts.theme.indexOf('jsonresume-theme-') > -1
    then new JRSTheme().open(tFolder) else new FRESHTheme().open( tFolder );

  # Cache the theme object
  _opts.themeObj = theTheme;
  theTheme

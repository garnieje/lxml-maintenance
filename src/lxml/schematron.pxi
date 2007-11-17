# support for Schematron validation
cimport schematron

'''
Schematron
----------

Schematron is a less well known, but very powerful schema language.  The main
idea is to use the capabilities of XPath to put restrictions on the structure
and the content of XML documents.  Here is a simple example::

  >>> schematron = etree.Schematron(etree.XML("""
  ... <schema xmlns="http://www.ascc.net/xml/schematron" >
  ...   <pattern name="id is the only permited attribute name">
  ...     <rule context="*">
  ...       <report test="@*[not(name()='id')]">Attribute
  ...         <name path="@*[not(name()='id')]"/> is forbidden<name/>
  ...       </report>
  ...     </rule>
  ...   </pattern>
  ... </schema>
  ... """))

  >>> xml = etree.XML("""
  ... <AAA name="aaa">
  ...   <BBB id="bbb"/>
  ...   <CCC color="ccc"/>
  ... </AAA>
  ... """)

  >>> schematron.validate(xml)
  0

  >>> xml = etree.XML("""
  ... <AAA id="aaa">
  ...   <BBB id="bbb"/>
  ...   <CCC/>
  ... </AAA>
  ... """)

  >>> schematron.validate(xml)
  1

Schematron was added to libxml2 in version 2.6.21.  As of version 2.6.27,
however, Schematron lacks support for error reporting other than to stderr.
It is therefore not possible to retrieve validation warnings and errors in
lxml.
'''

class SchematronError(LxmlError):
    """Base class of all Schematron errors.
    """
    pass

class SchematronParseError(SchematronError):
    """Error while parsing an XML document as Schematron schema.
    """
    pass

class SchematronValidateError(SchematronError):
    """Error while validating an XML document with a Schematron schema.
    """
    pass

################################################################################
# Schematron

cdef class Schematron(_Validator):
    """A Schematron validator.

    Pass a root Element or an ElementTree to turn it into a validator.
    Alternatively, pass a filename as keyword argument 'file' to parse from
    the file system.
    """
    cdef schematron.xmlSchematron* _c_schema
    def __init__(self, etree=None, file=None):
        cdef _Document doc
        cdef _Element root_node
        cdef xmlNode* c_node
        cdef xmlDoc* c_doc
        cdef char* c_href
        cdef schematron.xmlSchematronParserCtxt* parser_ctxt
        if not config.ENABLE_SCHEMATRON:
            raise SchematronError, \
                  "lxml.etree was compiled without Schematron support."
        self._c_schema = NULL
        if etree is not None:
            doc = _documentOrRaise(etree)
            root_node = _rootNodeOrRaise(etree)
            c_doc = _copyDocRoot(doc._c_doc, root_node._c_node)
            parser_ctxt = schematron.xmlSchematronNewDocParserCtxt(c_doc)
        elif file is not None:
            filename = _getFilenameForFile(file)
            if filename is None:
                # XXX assume a string object
                filename = file
            filename = _encodeFilename(filename)
            parser_ctxt = schematron.xmlSchematronNewParserCtxt(_cstr(filename))
            c_doc = NULL
        else:
            raise SchematronParseError, "No tree or file given"

        if parser_ctxt is NULL:
            python.PyErr_NoMemory()

        self._c_schema = schematron.xmlSchematronParse(parser_ctxt)

        schematron.xmlSchematronFreeParserCtxt(parser_ctxt)
        if self._c_schema is NULL:
            raise SchematronParseError, "Document is not a valid Schematron schema"
        _Validator.__init__(self)

    def __dealloc__(self):
        schematron.xmlSchematronFree(self._c_schema)

    def __call__(self, etree):
        """Validate doc using Schematron.

        Returns true if document is valid, false if not."""
        cdef python.PyThreadState* state
        cdef _Document doc
        cdef _Element root_node
        cdef xmlDoc* c_doc
        cdef schematron.xmlSchematronValidCtxt* valid_ctxt
        cdef int ret
        cdef int options

        doc = _documentOrRaise(etree)
        root_node = _rootNodeOrRaise(etree)

        self._error_log.connect()
        options = schematron.XML_SCHEMATRON_OUT_QUIET
        if tree.LIBXML_VERSION <= 20629:
            # hack to switch off stderr output
            options = options | schematron.XML_SCHEMATRON_OUT_XML
        valid_ctxt = schematron.xmlSchematronNewValidCtxt(
            self._c_schema, options)
        if valid_ctxt is NULL:
            self._error_log.disconnect()
            raise SchematronError, "Failed to create validation context"

        c_doc = _fakeRootDoc(doc._c_doc, root_node._c_node)
        state = python.PyEval_SaveThread()
        ret = schematron.xmlSchematronValidateDoc(valid_ctxt, c_doc)
        python.PyEval_RestoreThread(state)
        _destroyFakeDoc(doc._c_doc, c_doc)

        schematron.xmlSchematronFreeValidCtxt(valid_ctxt)

        self._error_log.disconnect()
        if ret == -1:
            raise SchematronValidateError, "Internal error in Schematron validation"
        if ret == 0:
            return True
        else:
            return False
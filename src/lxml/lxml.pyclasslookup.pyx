"""
A whole-tree Element class lookup scheme for `lxml.etree`.

This class lookup scheme allows access to the entire XML tree in
read-only mode.  To use it, let a class inherit from
`PythonElementClassLookup` and re-implement the ``lookup(self, doc,
root)`` method:

    >>> from lxml import etree, pyclasslookup
    >>>
    >>> class MyElementClass(etree.ElementBase):
    ...     honkey = True
    ...
    >>> class MyLookup(pyclasslookup.PythonElementClassLookup):
    ...     def lookup(self, doc, root):
    ...         if root.tag == "sometag":
    ...             return MyElementClass
    ...         else:
    ...             for child in root:
    ...                 if child.tag == "someothertag":
    ...                     return MyElementClass
    ...         # delegate to default
    ...         return None

Note that the API of the Element objects is not complete.  It is
purely read-only and does not support all features of the normal
`lxml.etree` API (such as XPath, extended slicing or some iteration
methods).

Also, you cannot wrap such a read-only Element in an ElementTree, and
you must take care not to keep a reference to them outside of the
`lookup()` method.

See http://codespeak.net/lxml/element_classes.html
"""

from etreepublic cimport _Document, _Element, ElementBase
from etreepublic cimport ElementClassLookup, FallbackElementClassLookup
from etreepublic cimport elementFactory, import_lxml__etree
from python cimport _cstr
cimport etreepublic as cetree
cimport python
cimport tree
cimport cstd

__all__ = ["PythonElementClassLookup"]

cdef object etree
from lxml import etree
# initialize C-API of lxml.etree
import_lxml__etree()

__version__ = etree.__version__

cdef class _ElementProxy:
    "The main read-only Element proxy class (for internal use only!)."
    cdef tree.xmlNode* _c_node
    cdef object _source_proxy
    cdef object _dependent_proxies

    cdef int _assertNode(self) except -1:
        """This is our way of saying: this proxy is invalid!
        """
        assert self._c_node is not NULL, "Proxy invalidated!"
        return 0

    property tag:
        """Element tag
        """
        def __get__(self):
            self._assertNode()
            return cetree.namespacedName(self._c_node)

    property text:
        """Text before the first subelement. This is either a string or 
        the value None, if there was no text.
        """
        def __get__(self):
            self._assertNode()
            return cetree.textOf(self._c_node)
        
    property tail:
        """Text after this element's end tag, but before the next sibling
        element's start tag. This is either a string or the value None, if
        there was no text.
        """
        def __get__(self):
            self._assertNode()
            return cetree.tailOf(self._c_node)

    property attrib:
        def __get__(self):
            self._assertNode()
            return dict(cetree.collectAttributes(self._c_node, 3))

    property prefix:
        """Namespace prefix or None.
        """
        def __get__(self):
            self._assertNode()
            if self._c_node.ns is not NULL:
                if self._c_node.ns.prefix is not NULL:
                    return cetree.pyunicode(self._c_node.ns.prefix)
            return None

    property sourceline:
        """Original line number as found by the parser or None if unknown.
        """
        def __get__(self):
            cdef long line
            self._assertNode()
            line = tree.xmlGetLineNo(self._c_node)
            if line > 0:
                return line
            else:
                return None

    def __repr__(self):
        return "<Element %s at %x>" % (self.tag, id(self))
    
    def __getitem__(self, Py_ssize_t index):
        """Returns the subelement at the given position.
        """
        cdef tree.xmlNode* c_node
        c_node = cetree.findChild(self._c_node, index)
        if c_node is NULL:
            raise IndexError("list index out of range")
        return _newProxy(self._source_proxy, c_node)

    def __getslice__(self, Py_ssize_t start, Py_ssize_t stop):
        """Returns a list containing subelements in the given range.
        """
        cdef tree.xmlNode* c_node
        cdef Py_ssize_t c
        c_node = cetree.findChild(self._c_node, start)
        if c_node is NULL:
            return []
        c = start
        result = []
        while c_node is not NULL and c < stop:
            if tree._isElement(c_node):
                python.PyList_Append(
                    result, _newProxy(self._source_proxy, c_node))
                c = c + 1
            c_node = c_node.next
        return result

    def __len__(self):
        """Returns the number of subelements.
        """
        cdef Py_ssize_t c
        cdef tree.xmlNode* c_node
        self._assertNode()
        c = 0
        c_node = self._c_node.children
        while c_node is not NULL:
            if tree._isElement(c_node):
                c = c + 1
            c_node = c_node.next
        return c

    def __nonzero__(self):
        cdef tree.xmlNode* c_node
        self._assertNode()
        c_node = cetree.findChildBackwards(self._c_node, 0)
        return c_node != NULL

    def __iter__(self):
        return iter(self.getchildren())

    def iterchildren(self, tag=None, *, reversed=False):
        """iterchildren(self, tag=None, reversed=False)

        Iterate over the children of this element.
        """
        children = self.getchildren()
        if tag is not None:
            children = [ el for el in children if el.tag == tag ]
        if reversed:
            children = children[::-1]
        return iter(children)

    def get(self, key, default=None):
        """Gets an element attribute.
        """
        self._assertNode()
        return _getAttributeValue(self._c_node, key, default)

    def keys(self):
        """Gets a list of attribute names. The names are returned in an
        arbitrary order (just like for an ordinary Python dictionary).
        """
        self._assertNode()
        return cetree.collectAttributes(self._c_node, 1)

    def values(self):
        """Gets element attributes, as a sequence. The attributes are returned
        in an arbitrary order.
        """
        self._assertNode()
        return cetree.collectAttributes(self._c_node, 2)

    def items(self):
        """Gets element attributes, as a sequence. The attributes are returned
        in an arbitrary order.
        """
        self._assertNode()
        return cetree.collectAttributes(self._c_node, 3)

    cpdef getchildren(self):
        """Returns all subelements. The elements are returned in document
        order.
        """
        cdef tree.xmlNode* c_node
        self._assertNode()
        result = []
        c_node = self._c_node.children
        while c_node is not NULL:
            if tree._isElement(c_node):
                python.PyList_Append(
                    result, _newProxy(self._source_proxy, c_node))
            c_node = c_node.next
        return result

    def getparent(self):
        """Returns the parent of this element or None for the root element.
        """
        cdef tree.xmlNode* c_parent
        self._assertNode()
        c_parent = self._c_node.parent
        if c_parent is NULL or not tree._isElement(c_parent):
            return None
        else:
            return _newProxy(self._source_proxy, c_parent)

    def getnext(self):
        """Returns the following sibling of this element or None.
        """
        cdef tree.xmlNode* c_node
        self._assertNode()
        c_node = cetree.nextElement(self._c_node)
        if c_node is not NULL:
            return _newProxy(self._source_proxy, c_node)
        return None

    def getprevious(self):
        """Returns the preceding sibling of this element or None.
        """
        cdef tree.xmlNode* c_node
        self._assertNode()
        c_node = cetree.previousElement(self._c_node)
        if c_node is not NULL:
            return _newProxy(self._source_proxy, c_node)
        return None


cdef extern from "etree_defs.h":
    # macro call to 't->tp_new()' for fast instantiation
    cdef _ElementProxy NEW_PROXY "PY_NEW" (object t)

cdef _ElementProxy _newProxy(_ElementProxy sourceProxy, tree.xmlNode* c_node):
    cdef _ElementProxy el
    el = NEW_PROXY(_ElementProxy)
    el._c_node = c_node
    if sourceProxy is None:
        el._source_proxy = el
        el._dependent_proxies = [el]
    else:
        el._source_proxy = sourceProxy
        python.PyList_Append(sourceProxy._dependent_proxies, el)
    return el

cdef _freeProxies(_ElementProxy sourceProxy):
    cdef _ElementProxy el
    if sourceProxy is None:
        return
    if sourceProxy._dependent_proxies is None:
        return
    for el in sourceProxy._dependent_proxies:
        el._c_node = NULL
    del sourceProxy._dependent_proxies[:]

cdef object _getAttributeValue(tree.xmlNode* c_node, key, default):
    cdef char* c_tag
    cdef char* c_href
    ns, tag = cetree.getNsTag(key)
    c_tag = _cstr(tag)
    if ns is None:
        c_href = NULL
    else:
        c_href = _cstr(ns)
    result = cetree.attributeValueFromNsName(c_node, c_href, c_tag)
    if result is None:
        return default
    return result


cdef class PythonElementClassLookup(FallbackElementClassLookup):
    """PythonElementClassLookup(self, fallback=None)
    Element class lookup based on a subclass method.

    To use it, inherit from this class and override the lookup method to
    lookup the element class for a node::

        lookup(self, document, node_proxy)

    The first argument is the opaque document instance that contains the
    Element. The second arguments is a lightweight Element proxy
    implementation that is only valid during the lookup. Do not try to keep a
    reference to it. Once the lookup is done, the proxy will be invalid.

    If you return None from this method, the fallback will be called.
    """
    def __init__(self, ElementClassLookup fallback=None):
        FallbackElementClassLookup.__init__(self, fallback)
        self._lookup_function = _lookup_class

    def lookup(self, doc, element):
        """lookup(self, doc, element)

        Override this method to implement your own lookup scheme.
        """
        return None

cdef object _lookup_class(state, _Document doc, tree.xmlNode* c_node):
    cdef PythonElementClassLookup lookup
    cdef _ElementProxy proxy
    lookup = <PythonElementClassLookup>state

    proxy = _newProxy(None, c_node)
    cls = lookup.lookup(doc, proxy)
    _freeProxies(proxy)

    if cls is not None:
        return cls
    return cetree.callLookupFallback(lookup, doc, c_node)
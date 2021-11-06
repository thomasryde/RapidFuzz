# distutils: language=c++
# cython: language_level=3, binding=True, linetrace=True

from rapidfuzz.utils import default_process
from rapidfuzz.fuzz import WRatio

from libcpp.vector cimport vector
from libcpp cimport algorithm
from libcpp.utility cimport move
from libc.stdint cimport uint8_t, int32_t
from libc.math cimport floor

from cpython.list cimport PyList_New, PyList_SET_ITEM
from cpython.ref cimport Py_INCREF
from cython.operator cimport dereference

from cpp_common cimport (
    PyObjectWrapper, RF_StringWrapper, RF_KwargsWrapper, KwargsInit,
    is_valid_string, convert_string, hash_array, hash_sequence
)

import heapq
from array import array

from rapidfuzz_capi cimport (
    RF_Preprocess, RF_String, RF_Distance, RF_Similarity, RF_Scorer,
    RF_DistanceInit, RF_SimilarityInit,
    RF_SIMILARITY, RF_DISTANCE
)
from cpython.pycapsule cimport PyCapsule_IsValid, PyCapsule_GetPointer

cdef inline RF_String conv_sequence(seq) except *:
    if is_valid_string(seq):
        return move(convert_string(seq))
    elif isinstance(seq, array):
        return move(hash_array(seq))
    else:
        return move(hash_sequence(seq))

cdef extern from "rapidfuzz/details/types.hpp" namespace "rapidfuzz" nogil:
    cdef struct LevenshteinWeightTable:
        size_t insert_cost
        size_t delete_cost
        size_t replace_cost

cdef extern from "cpp_process.hpp":
    ctypedef struct ExtractScorerComp:
        pass

    ctypedef struct ListMatchScorerElem:
        double score
        size_t index
        PyObjectWrapper choice

    ctypedef struct DictMatchScorerElem:
        double score
        size_t index
        PyObjectWrapper choice
        PyObjectWrapper key

    ctypedef struct ExtractDistanceComp:
        pass

    ctypedef struct ListMatchDistanceElem:
        size_t distance
        size_t index
        PyObjectWrapper choice

    ctypedef struct DictMatchDistanceElem:
        size_t distance
        size_t index
        PyObjectWrapper choice
        PyObjectWrapper key

    cdef cppclass RF_SimilarityWrapper:
        RF_SimilarityWrapper()
        RF_SimilarityWrapper(RF_Similarity)
        void similarity(const RF_String*, double, double*) except +

    cdef cppclass RF_DistanceWrapper:
        RF_DistanceWrapper()
        RF_DistanceWrapper(RF_Distance)
        void distance(const RF_String*, size_t, size_t*) except +

# todo support different scorers
default_process_capsule = getattr(default_process, '_RF_Preprocess')
if not PyCapsule_IsValid(default_process_capsule, NULL):
    raise RuntimeError("PyCapsule missing from utils.default_process")
cdef RF_Preprocess default_process_func = <RF_Preprocess>PyCapsule_GetPointer(default_process_capsule, NULL)

cdef inline extractOne_dict(RF_SimilarityWrapper context, choices, processor, double score_cutoff):
    """
    implementation of extractOne for:
      - type of choices = dict
      - scorer = normalized scorer implemented in C++
    """
    cdef double score
    # use -1 as score, so even a score of 0 in the first iteration is higher
    cdef double result_score = -1
    cdef int def_process = 0
    cdef RF_String proc_str
    result_choice = None
    result_key = None

    if processor is default_process:
        def_process = 1

    for choice_key, choice in choices.items():
        if choice is None:
            continue

        if def_process:
            default_process_func(choice, &proc_str)
            choice_proc = RF_StringWrapper(proc_str)
            context.similarity(&choice_proc.string, score_cutoff, &score)
        elif processor is not None:
            proc_choice = processor(choice)
            if proc_choice is None:
                continue

            choice_proc = RF_StringWrapper(conv_sequence(proc_choice))
            context.similarity(&choice_proc.string, score_cutoff, &score)
        else:
            choice_proc = RF_StringWrapper(conv_sequence(choice))
            context.similarity(&choice_proc.string, score_cutoff, &score)

        if score >= score_cutoff and score > result_score:
            result_score = score_cutoff = score
            result_choice = choice
            result_key = choice_key

            if result_score == 100:
                break

    return (result_choice, result_score, result_key) if result_choice is not None else None


cdef inline extractOne_distance_dict(RF_DistanceWrapper context, choices, processor, size_t max_):
    """
    implementation of extractOne for:
      - type of choices = dict
      - scorer = Distance implemented in C++
    """
    cdef size_t distance
    cdef size_t result_distance = <size_t>-1
    cdef int def_process = 0
    cdef RF_String proc_str
    result_choice = None
    result_key = None

    if processor is default_process:
        def_process = 1

    for choice_key, choice in choices.items():
        if choice is None:
            continue

        if def_process:
            default_process_func(choice, &proc_str)
            choice_proc = RF_StringWrapper(proc_str)
            context.distance(&choice_proc.string, max_, &distance)
        elif processor is not None:
            proc_choice = processor(choice)
            if proc_choice is None:
                continue

            choice_proc = RF_StringWrapper(conv_sequence(proc_choice))
            context.distance(&choice_proc.string, max_, &distance)
        else:
            choice_proc = RF_StringWrapper(conv_sequence(choice))
            context.distance(&choice_proc.string, max_, &distance)

        if distance <= max_ and distance < result_distance:
            result_distance = max_ = distance
            result_choice = choice
            result_key = choice_key

            if result_distance == 0:
                break

    return (result_choice, result_distance, result_key) if result_choice is not None else None


cdef inline extractOne_list(RF_SimilarityWrapper context, choices, processor, double score_cutoff):
    """
    implementation of extractOne for:
      - type of choices = list
      - scorer = normalized scorer implemented in C++
    """
    cdef double score = 0.0
    # use -1 as score, so even a score of 0 in the first iteration is higher
    cdef double result_score = -1
    cdef size_t i
    cdef size_t result_index = 0
    cdef int def_process = 0
    cdef RF_String proc_str
    result_choice = None

    if processor is default_process:
        def_process = 1

    for i, choice in enumerate(choices):
        if choice is None:
            continue

        if def_process:
            default_process_func(choice, &proc_str)
            choice_proc = RF_StringWrapper(proc_str)
            context.similarity(&choice_proc.string, score_cutoff, &score)
        elif processor is not None:
            proc_choice = processor(choice)
            if proc_choice is None:
                continue

            choice_proc = RF_StringWrapper(conv_sequence(proc_choice))
            context.similarity(&choice_proc.string, score_cutoff, &score)
        else:
            choice_proc = RF_StringWrapper(conv_sequence(choice))
            context.similarity(&choice_proc.string, score_cutoff, &score)

        if score >= score_cutoff and score > result_score:
            result_score = score_cutoff = score
            result_choice = choice
            result_index = i

            if result_score == 100:
                break

    return (result_choice, result_score, result_index) if result_choice is not None else None


cdef inline extractOne_distance_list(RF_DistanceWrapper context, choices, processor, size_t max_):
    """
    implementation of extractOne for:
      - type of choices = list
      - scorer = Distance implemented in C++
    """
    cdef size_t distance
    cdef size_t result_distance = <size_t>-1
    cdef size_t i
    cdef size_t result_index = 0
    cdef int def_process = 0
    cdef RF_String proc_str
    result_choice = None

    if processor is default_process:
        def_process = 1

    for i, choice in enumerate(choices):
        if choice is None:
            continue

        if def_process:
            default_process_func(choice, &proc_str)
            choice_proc = RF_StringWrapper(proc_str)
            context.distance(&choice_proc.string, max_, &distance)
        elif processor is not None:
            proc_choice = processor(choice)
            if proc_choice is None:
                continue

            choice_proc = RF_StringWrapper(conv_sequence(proc_choice))
            context.distance(&choice_proc.string, max_, &distance)
        else:
            choice_proc = RF_StringWrapper(conv_sequence(choice))
            context.distance(&choice_proc.string, max_, &distance)

        if distance <= max_ and distance < result_distance:
            result_distance = max_ = distance
            result_choice = choice
            result_index = i

            if result_distance == 0:
                break

    return (result_choice, result_distance, result_index) if result_choice is not None else None


cdef inline py_extractOne_dict(query, choices, scorer, processor, double score_cutoff, dict kwargs):
    result_score = -1
    result_choice = None
    result_key = None

    for choice_key, choice in choices.items():
        if choice is None:
            continue

        if processor is not None:
            score = scorer(query, processor(choice), **kwargs)
        else:
            score = scorer(query, choice, **kwargs)

        if score >= score_cutoff and score > result_score:
            score_cutoff = score
            kwargs["score_cutoff"] = score
            result_score = score
            result_choice = choice
            result_key = choice_key

            if score_cutoff == 100:
                break

    return (result_choice, result_score, result_key) if result_choice is not None else None


cdef inline py_extractOne_list(query, choices, scorer, processor, double score_cutoff, dict kwargs):
    cdef size_t result_index = 0
    cdef size_t i
    result_score = -1
    result_choice = None

    for i, choice in enumerate(choices):
        if choice is None:
            continue

        if processor is not None:
            score = scorer(query, processor(choice), **kwargs)
        else:
            score = scorer(query, choice, **kwargs)

        if score >= score_cutoff and score > result_score:
            score_cutoff = score
            kwargs["score_cutoff"] = score
            result_score = score
            result_choice = choice
            result_index = i

            if score_cutoff == 100:
                break

    return (result_choice, result_score, result_index) if result_choice is not None else None


def extractOne(query, choices, *, scorer=WRatio, processor=default_process, score_cutoff=None, **kwargs):
    """
    Find the best match in a list of choices. When multiple elements have the same similarity,
    the first element is returned.

    Parameters
    ----------
    query : Sequence[Hashable]
        string we want to find
    choices : Iterable[Sequence[Hashable]] | Mapping[Sequence[Hashable]]
        list of all strings the query should be compared with or dict with a mapping
        {<result>: <string to compare>}
    scorer : Callable, optional
        Optional callable that is used to calculate the matching score between
        the query and each choice. This can be any of the scorers included in RapidFuzz
        (both scorers that calculate the edit distance or the normalized edit distance), or
        a custom function, which returns a normalized edit distance.
        fuzz.WRatio is used by default.
    processor : Callable, optional
        Optional callable that reformats the strings.
        utils.default_process is used by default, which lowercases the strings and trims whitespace
    score_cutoff : Any, optional
        Optional argument for a score threshold. When an edit distance is used this represents the maximum
        edit distance and matches with a `distance <= score_cutoff` are ignored. When a
        normalized edit distance is used this represents the minimal similarity
        and matches with a `similarity >= score_cutoff` are ignored. For edit distances this defaults to
        -1, while for normalized edit distances this defaults to 0.0, which deactivates this behaviour.
    **kwargs : Any, optional
        any other named parameters are passed to the scorer. This can be used to pass
        e.g. weights to string_metric.levenshtein

    Returns
    -------
    Tuple[Sequence[Hashable], Any, Any]
        Returns the best match in form of a Tuple with 3 elements. The values stored in the
        tuple depend on the types of the input arguments.

        * The first element is always the `choice`, which is the value thats compared to the query.

        * The second value represents the similarity calculated by the scorer. This can be:

          * An edit distance (distance is 0 for a perfect match and > 0 for non perfect matches).
            In this case only choices which have a `distance <= score_cutoff` are returned.
            An example of a scorer with this behavior is `string_metric.levenshtein`.
          * A normalized edit distance (similarity is a score between 0 and 100, with 100 being a perfect match).
            In this case only choices which have a `similarity >= score_cutoff` are returned.
            An example of a scorer with this behavior is `string_metric.normalized_levenshtein`.

          Note, that for all scorers, which are not provided by RapidFuzz, only normalized edit distances are supported.

        * The third parameter depends on the type of the `choices` argument it is:

          * The `index of choice` when choices is a simple iterable like a list
          * The `key of choice` when choices is a mapping like a dict, or a pandas Series

    None
        When no choice has a `similarity >= score_cutoff`/`distance <= score_cutoff` None is returned

    Examples
    --------

    >>> from rapidfuzz.process import extractOne
    >>> from rapidfuzz.string_metric import levenshtein, normalized_levenshtein
    >>> from rapidfuzz.fuzz import ratio

    extractOne can be used with normalized edit distances.

    >>> extractOne("abcd", ["abce"], scorer=ratio)
    ("abcd", 75.0, 1)
    >>> extractOne("abcd", ["abce"], scorer=normalized_levenshtein)
    ("abcd", 75.0, 1)

    extractOne can be used with edit distances as well.

    >>> extractOne("abcd", ["abce"], scorer=levenshtein)
    ("abce", 1, 0)

    additional settings of the scorer can be passed as keyword arguments to extractOne

    >>> extractOne("abcd", ["abce"], scorer=levenshtein, weights=(1,1,2))
    ("abcde", 2, 1)

    when a mapping is used for the choices the key of the choice is returned instead of the List index

    >>> extractOne("abcd", {"key": "abce"}, scorer=ratio)
    ("abcd", 75.0, "key")

    By default each string is preprocessed using `utils.default_process`, which lowercases the strings,
    replaces non alphanumeric characters with whitespaces and trims whitespaces from start and end of them.
    This behavior can be changed by passing a custom function, or None/False to disable the behavior. Preprocessing
    can take a significant part of the runtime, so it makes sense to disable it, when it is not required.


    >>> extractOne("abcd", ["abdD"], scorer=ratio)
    ("abcD", 100.0, 0)
    >>> extractOne("abcd", ["abdD"], scorer=ratio, processor=None)
    ("abcD", 75.0, 0)
    >>> extractOne("abcd", ["abdD"], scorer=ratio, processor=lambda s: s.upper())
    ("abcD", 100.0, 0)

    When only results with a similarity above a certain threshold are relevant, the parameter score_cutoff can be
    used to filter out results with a lower similarity. This threshold is used by some of the scorers to exit early,
    when they are sure, that the similarity is below the threshold.
    For normalized edit distances all results with a similarity below score_cutoff are filtered out

    >>> extractOne("abcd", ["abce"], scorer=ratio)
    ("abce", 75.0, 0)
    >>> extractOne("abcd", ["abce"], scorer=ratio, score_cutoff=80)
    None

    For edit distances all results with an edit distance above the score_cutoff are filtered out

    >>> extractOne("abcd", ["abce"], scorer=levenshtein, weights=(1,1,2))
    ("abce", 2, 0)
    >>> extractOne("abcd", ["abce"], scorer=levenshtein, weights=(1,1,2), score_cutoff=1)
    None

    """
    cdef double c_score_cutoff = 0.0
    cdef size_t c_max = <size_t>-1
    cdef RF_KwargsWrapper kwargs_context
    cdef RF_Similarity similarity_context
    cdef RF_Distance distance_context
    cdef RF_Scorer* scorer_context = NULL

    if query is None:
        return None

    if not processor:
        processor = None

    # preprocess the query
    if callable(processor):
        query = processor(query)
    elif processor:
        query = default_process(query)
        processor = default_process

    scorer_capsule = getattr(scorer, '_RF_Scorer', scorer)
    if PyCapsule_IsValid(scorer_capsule, NULL):
        scorer_context = <RF_Scorer*>PyCapsule_GetPointer(scorer_capsule, NULL)
        kwargs_context = KwargsInit(dereference(scorer_context), kwargs)

    if scorer_context and scorer_context.scorer_type == RF_SIMILARITY:
        query_context = RF_StringWrapper(conv_sequence(query))
        scorer_context.scorer.similarity_init(&similarity_context, &kwargs_context.kwargs, 1, &query_context.string)
        ScorerContext = RF_SimilarityWrapper(similarity_context)
        if score_cutoff is not None:
            c_score_cutoff = score_cutoff
        if c_score_cutoff < 0 or c_score_cutoff > 100:
            raise TypeError("score_cutoff has to be in the range of 0.0 - 100.0")

        if hasattr(choices, "items"):
            return extractOne_dict(move(ScorerContext), choices, processor, c_score_cutoff)
        else:
            return extractOne_list(move(ScorerContext), choices, processor, c_score_cutoff)

    if scorer_context and scorer_context.scorer_type == RF_DISTANCE:
        query_context = RF_StringWrapper(conv_sequence(query))
        scorer_context.scorer.distance_init(&distance_context, &kwargs_context.kwargs, 1, &query_context.string)
        DistanceContext = RF_DistanceWrapper(distance_context)
        if score_cutoff is not None and score_cutoff != -1:
            c_max = score_cutoff

        if hasattr(choices, "items"):
            return extractOne_distance_dict(move(DistanceContext), choices, processor, c_max)
        else:
            return extractOne_distance_list(move(DistanceContext), choices, processor, c_max)

    # the scorer has to be called through Python
    if score_cutoff is not None:
        c_score_cutoff = score_cutoff

    kwargs["processor"] = None
    kwargs["score_cutoff"] = score_cutoff

    if hasattr(choices, "items"):
        return py_extractOne_dict(query, choices, scorer, processor, c_score_cutoff, kwargs)
    else:
        return py_extractOne_list(query, choices, scorer, processor, c_score_cutoff, kwargs)


cdef inline extract_dict(RF_SimilarityWrapper context, choices, processor, size_t limit, double score_cutoff):
    cdef double score = 0.0
    cdef size_t i
    cdef vector[DictMatchScorerElem] results
    results.reserve(<size_t>len(choices))
    cdef list result_list
    cdef int def_process = 0
    cdef RF_String proc_str

    if processor is default_process:
        def_process = 1

    for i, (choice_key, choice) in enumerate(choices.items()):
        if choice is None:
            continue

        if def_process:
            default_process_func(choice, &proc_str)
            choice_proc = RF_StringWrapper(proc_str)
            context.similarity(&choice_proc.string, score_cutoff, &score)
        elif processor is not None:
            proc_choice = processor(choice)
            if proc_choice is None:
                continue

            choice_proc = RF_StringWrapper(conv_sequence(proc_choice))
            context.similarity(&choice_proc.string, score_cutoff, &score)
        else:
            choice_proc = RF_StringWrapper(conv_sequence(choice))
            context.similarity(&choice_proc.string, score_cutoff, &score)

        if score >= score_cutoff:
            results.push_back(move(DictMatchScorerElem(score, i, PyObjectWrapper(choice), PyObjectWrapper(choice_key))))

    # due to score_cutoff not always completely filled
    if limit > results.size():
        limit = results.size()

    if limit >= results.size():
        algorithm.sort(results.begin(), results.end(), ExtractScorerComp())
    else:
        algorithm.partial_sort(results.begin(), results.begin() + <ptrdiff_t>limit, results.end(), ExtractScorerComp())
        results.resize(limit)

    # copy elements into Python List
    result_list = PyList_New(<Py_ssize_t>limit)
    for i in range(limit):
        result_item = (<object>results[i].choice.obj, results[i].score, <object>results[i].key.obj)
        Py_INCREF(result_item)
        PyList_SET_ITEM(result_list, <Py_ssize_t>i, result_item)

    return result_list


cdef inline extract_distance_dict(RF_DistanceWrapper context, choices, processor, size_t limit, size_t max_):
    cdef size_t distance
    cdef size_t i
    cdef vector[DictMatchDistanceElem] results
    results.reserve(<size_t>len(choices))
    cdef list result_list
    cdef int def_process = 0
    cdef RF_String proc_str

    if processor is default_process:
        def_process = 1

    for i, (choice_key, choice) in enumerate(choices.items()):
        if choice is None:
            continue

        if def_process:
            default_process_func(choice, &proc_str)
            choice_proc = RF_StringWrapper(proc_str)
            context.distance(&choice_proc.string, max_, &distance)
        elif processor is not None:
            proc_choice = processor(choice)
            if proc_choice is None:
                continue

            choice_proc = RF_StringWrapper(conv_sequence(proc_choice))
            context.distance(&choice_proc.string, max_, &distance)
        else:
            choice_proc = RF_StringWrapper(conv_sequence(choice))
            context.distance(&choice_proc.string, max_, &distance)

        if distance <= max_:
            results.push_back(move(DictMatchDistanceElem(distance, i, PyObjectWrapper(choice), PyObjectWrapper(choice_key))))

    # due to max_ not always completely filled
    if limit > results.size():
        limit = results.size()

    if limit >= results.size():
        algorithm.sort(results.begin(), results.end(), ExtractDistanceComp())
    else:
        algorithm.partial_sort(results.begin(), results.begin() + <ptrdiff_t>limit, results.end(), ExtractDistanceComp())
        results.resize(limit)

    # copy elements into Python List
    result_list = PyList_New(<Py_ssize_t>limit)
    for i in range(limit):
        result_item = (<object>results[i].choice.obj, results[i].distance, <object>results[i].key.obj)
        Py_INCREF(result_item)
        PyList_SET_ITEM(result_list, <Py_ssize_t>i, result_item)

    return result_list


cdef inline extract_list(RF_SimilarityWrapper context, choices, processor, size_t limit, double score_cutoff):
    cdef double score = 0.0
    cdef size_t i
    # todo possibly a smaller vector would be good to reduce memory usage
    cdef vector[ListMatchScorerElem] results
    results.reserve(<size_t>len(choices))
    cdef list result_list
    cdef int def_process = 0
    cdef RF_String proc_str

    if processor is default_process:
        def_process = 1

    for i, choice in enumerate(choices):
        if choice is None:
            continue

        if def_process:
            default_process_func(choice, &proc_str)
            choice_proc = RF_StringWrapper(proc_str)
            context.similarity(&choice_proc.string, score_cutoff, &score)
        elif processor is not None:
            proc_choice = processor(choice)
            if proc_choice is None:
                continue

            choice_proc = RF_StringWrapper(conv_sequence(proc_choice))
            context.similarity(&choice_proc.string, score_cutoff, &score)
        else:
            choice_proc = RF_StringWrapper(conv_sequence(choice))
            context.similarity(&choice_proc.string, score_cutoff, &score)

        if score >= score_cutoff:
            results.push_back(move(ListMatchScorerElem(score, i, PyObjectWrapper(choice))))

    # due to score_cutoff not always completely filled
    if limit > results.size():
        limit = results.size()

    if limit >= results.size():
        algorithm.sort(results.begin(), results.end(), ExtractScorerComp())
    else:
        algorithm.partial_sort(results.begin(), results.begin() + <ptrdiff_t>limit, results.end(), ExtractScorerComp())
        results.resize(limit)

    # copy elements into Python List
    result_list = PyList_New(<Py_ssize_t>limit)
    for i in range(limit):
        result_item = (<object>results[i].choice.obj, results[i].score, results[i].index)
        Py_INCREF(result_item)
        PyList_SET_ITEM(result_list, <Py_ssize_t>i, result_item)


    return result_list


cdef inline extract_distance_list(RF_DistanceWrapper context, choices, processor, size_t limit, size_t max_):
    cdef size_t distance
    cdef size_t i
    # todo possibly a smaller vector would be good to reduce memory usage
    cdef vector[ListMatchDistanceElem] results
    results.reserve(<size_t>len(choices))
    cdef list result_list
    cdef int def_process = 0
    cdef RF_String proc_str

    if processor is default_process:
        def_process = 1

    for i, choice in enumerate(choices):
        if choice is None:
            continue

        if def_process:
            default_process_func(choice, &proc_str)
            choice_proc = RF_StringWrapper(proc_str)
            context.distance(&choice_proc.string, max_, &distance)
        elif processor is not None:
            proc_choice = processor(choice)
            if proc_choice is None:
                continue

            choice_proc = RF_StringWrapper(conv_sequence(proc_choice))
            context.distance(&choice_proc.string, max_, &distance)
        else:
            choice_proc = RF_StringWrapper(conv_sequence(choice))
            context.distance(&choice_proc.string, max_, &distance)

        if distance <= max_:
            results.push_back(move(ListMatchDistanceElem(distance, i, PyObjectWrapper(choice))))

    # due to max_ not always completely filled
    if limit > results.size():
        limit = results.size()

    if limit >= results.size():
        algorithm.sort(results.begin(), results.end(), ExtractDistanceComp())
    else:
        algorithm.partial_sort(results.begin(), results.begin() + <ptrdiff_t>limit, results.end(), ExtractDistanceComp())
        results.resize(limit)

    # copy elements into Python List
    result_list = PyList_New(<Py_ssize_t>limit)
    for i in range(limit):
        result_item = (<object>results[i].choice.obj, results[i].distance, results[i].index)
        Py_INCREF(result_item)
        PyList_SET_ITEM(result_list, <Py_ssize_t>i, result_item)

    return result_list

cdef inline py_extract_dict(query, choices, scorer, processor, size_t limit, double score_cutoff, dict kwargs):
    cdef object score = None
    # todo working directly with a list is relatively slow
    # also it is not very memory efficient to allocate space for all elements even when only
    # a part is used. This should be optimised in the future
    cdef list result_list = []

    for choice_key, choice in choices.items():
        if choice is None:
            continue

        if processor is not None:
            score = scorer(query, processor(choice), **kwargs)
        else:
            score = scorer(query, choice, **kwargs)

        if score >= score_cutoff:
            result_list.append((choice, score, choice_key))

    return heapq.nlargest(limit, result_list, key=lambda i: i[1])


cdef inline py_extract_list(query, choices, scorer, processor, size_t limit, double score_cutoff, dict kwargs):
    cdef object score = None
    # todo working directly with a list is relatively slow
    # also it is not very memory efficient to allocate space for all elements even when only
    # a part is used. This should be optimised in the future
    cdef list result_list = []
    cdef size_t i

    for i, choice in enumerate(choices):
        if choice is None:
            continue

        if processor is not None:
            score = scorer(query, processor(choice), **kwargs)
        else:
            score = scorer(query, choice, **kwargs)

        if score >= score_cutoff:
            result_list.append((choice, score, i))

    return heapq.nlargest(limit, result_list, key=lambda i: i[1])


def extract(query, choices, *, scorer=WRatio, processor=default_process, limit=5, score_cutoff=None, **kwargs):
    """
    Find the best matches in a list of choices. The list is sorted by the similarity.
    When multiple choices have the same similarity, they are sorted by their index

    Parameters
    ----------
    query : Sequence[Hashable]
        string we want to find
    choices : Collection[Sequence[Hashable]] | Mapping[Sequence[Hashable]]
        list of all strings the query should be compared with or dict with a mapping
        {<result>: <string to compare>}
    scorer : Callable, optional
        Optional callable that is used to calculate the matching score between
        the query and each choice. This can be any of the scorers included in RapidFuzz
        (both scorers that calculate the edit distance or the normalized edit distance), or
        a custom function, which returns a normalized edit distance.
        fuzz.WRatio is used by default.
    processor : Callable, optional
        Optional callable that reformats the strings.
        utils.default_process is used by default, which lowercases the strings and trims whitespace
    limit : int
        maximum amount of results to return
    score_cutoff : Any, optional
        Optional argument for a score threshold. When an edit distance is used this represents the maximum
        edit distance and matches with a `distance <= score_cutoff` are ignored. When a
        normalized edit distance is used this represents the minimal similarity
        and matches with a `similarity >= score_cutoff` are ignored. For edit distances this defaults to
        -1, while for normalized edit distances this defaults to 0.0, which deactivates this behaviour.
    **kwargs : Any, optional
        any other named parameters are passed to the scorer. This can be used to pass
        e.g. weights to string_metric.levenshtein

    Returns
    -------
    List[Tuple[Sequence[Hashable], Any, Any]]
        The return type is always a List of Tuples with 3 elements. However the values stored in the
        tuple depend on the types of the input arguments.

        * The first element is always the `choice`, which is the value thats compared to the query.

        * The second value represents the similarity calculated by the scorer. This can be:

          * An edit distance (distance is 0 for a perfect match and > 0 for non perfect matches).
            In this case only choices which have a `distance <= max` are returned.
            An example of a scorer with this behavior is `string_metric.levenshtein`.
          * A normalized edit distance (similarity is a score between 0 and 100, with 100 being a perfect match).
            In this case only choices which have a `similarity >= score_cutoff` are returned.
            An example of a scorer with this behavior is `string_metric.normalized_levenshtein`.

          Note, that for all scorers, which are not provided by RapidFuzz, only normalized edit distances are supported.

        * The third parameter depends on the type of the `choices` argument it is:

          * The `index of choice` when choices is a simple iterable like a list
          * The `key of choice` when choices is a mapping like a dict, or a pandas Series

        The list is sorted by `score_cutoff` or `max` depending on the scorer used. The first element in the list
        has the `highest similarity`/`smallest distance`.

    """
    cdef double c_score_cutoff = 0.0
    cdef size_t c_max = <size_t>-1
    cdef int def_process = 0
    cdef RF_KwargsWrapper kwargs_context
    cdef RF_Similarity similarity_context
    cdef RF_Distance distance_context
    cdef RF_Scorer* scorer_context = NULL

    if query is None:
        return []

    if limit is None or limit > len(choices):
        limit = len(choices)

    if not processor:
        processor = None

    # preprocess the query
    if callable(processor):
        query = processor(query)
    elif processor:
        query = default_process(query)
        processor = default_process

    scorer_capsule = getattr(scorer, '_RF_Scorer', scorer)
    if PyCapsule_IsValid(scorer_capsule, NULL):
        scorer_context = <RF_Scorer*>PyCapsule_GetPointer(scorer_capsule, NULL)
        kwargs_context = KwargsInit(dereference(scorer_context), kwargs)

    if scorer_context and scorer_context.scorer_type == RF_SIMILARITY:
        query_context = RF_StringWrapper(conv_sequence(query))
        scorer_context.scorer.similarity_init(&similarity_context, &kwargs_context.kwargs, 1, &query_context.string)
        ScorerContext = RF_SimilarityWrapper(similarity_context)
        if score_cutoff is not None:
            c_score_cutoff = score_cutoff
        if c_score_cutoff < 0 or c_score_cutoff > 100:
            raise TypeError("score_cutoff has to be in the range of 0.0 - 100.0")

        if hasattr(choices, "items"):
            return extract_dict(move(ScorerContext), choices, processor, limit, c_score_cutoff)
        else:
            return extract_list(move(ScorerContext), choices, processor, limit, c_score_cutoff)

    if scorer_context and scorer_context.scorer_type == RF_DISTANCE:
        query_context = RF_StringWrapper(conv_sequence(query))
        scorer_context.scorer.distance_init(&distance_context, &kwargs_context.kwargs, 1, &query_context.string)
        DistanceContext = RF_DistanceWrapper(distance_context)
        if score_cutoff is not None and score_cutoff != -1:
            c_max = score_cutoff

        if hasattr(choices, "items"):
            return extract_distance_dict(move(DistanceContext), choices, processor, limit, c_max)
        else:
            return extract_distance_list(move(DistanceContext), choices, processor, limit, c_max)

    # the scorer has to be called through Python
    if score_cutoff is not None:
        c_score_cutoff = score_cutoff

    kwargs["processor"] = None
    kwargs["score_cutoff"] = score_cutoff

    if hasattr(choices, "items"):
        return py_extract_dict(query, choices, scorer, processor, limit, c_score_cutoff, kwargs)
    else:
        return py_extract_list(query, choices, scorer, processor, limit, c_score_cutoff, kwargs)

def extract_iter(query, choices, *, scorer=WRatio, processor=default_process, score_cutoff=None, **kwargs):
    """
    Find the best match in a list of choices

    Parameters
    ----------
    query : Sequence[Hashable]
        string we want to find
    choices : Iterable[Sequence[Hashable]] | Mapping[Sequence[Hashable]]
        list of all strings the query should be compared with or dict with a mapping
        {<result>: <string to compare>}
    scorer : Callable, optional
        Optional callable that is used to calculate the matching score between
        the query and each choice. This can be any of the scorers included in RapidFuzz
        (both scorers that calculate the edit distance or the normalized edit distance), or
        a custom function, which returns a normalized edit distance.
        fuzz.WRatio is used by default.
    processor : Callable, optional
        Optional callable that reformats the strings.
        utils.default_process is used by default, which lowercases the strings and trims whitespace
    score_cutoff : Any, optional
        Optional argument for a score threshold. When an edit distance is used this represents the maximum
        edit distance and matches with a `distance <= score_cutoff` are ignored. When a
        normalized edit distance is used this represents the minimal similarity
        and matches with a `similarity >= score_cutoff` are ignored. For edit distances this defaults to
        -1, while for normalized edit distances this defaults to 0.0, which deactivates this behaviour.
    **kwargs : Any, optional
        any other named parameters are passed to the scorer. This can be used to pass
        e.g. weights to string_metric.levenshtein

    Yields
    -------
    Tuple[Sequence[Hashable], Any, Any]
        Yields similarity between the query and each choice in form of a Tuple with 3 elements.
        The values stored in the tuple depend on the types of the input arguments.

        * The first element is always the current `choice`, which is the value thats compared to the query.

        * The second value represents the similarity calculated by the scorer. This can be:

          * An edit distance (distance is 0 for a perfect match and > 0 for non perfect matches).
            In this case only choices which have a `distance <= max` are yielded.
            An example of a scorer with this behavior is `string_metric.levenshtein`.
          * A normalized edit distance (similarity is a score between 0 and 100, with 100 being a perfect match).
            In this case only choices which have a `similarity >= score_cutoff` are yielded.
            An example of a scorer with this behavior is `string_metric.normalized_levenshtein`.

          Note, that for all scorers, which are not provided by RapidFuzz, only normalized edit distances are supported.

        * The third parameter depends on the type of the `choices` argument it is:

          * The `index of choice` when choices is a simple iterable like a list
          * The `key of choice` when choices is a mapping like a dict, or a pandas Series

    """
    cdef double c_score_cutoff = 0.0
    cdef size_t c_max = <size_t>-1
    cdef RF_KwargsWrapper kwargs_context
    cdef RF_SimilarityWrapper ScorerContext
    cdef RF_DistanceWrapper DistanceContext
    cdef RF_Similarity similarity_context
    cdef RF_Distance distance_context
    cdef RF_Scorer* scorer_context = NULL
    cdef RF_String proc_str

    def extract_iter_dict():
        """
        implementation of extract_iter for:
          - type of choices = dict
          - scorer = normalized scorer implemented in C++
        """
        cdef double score

        for choice_key, choice in choices.items():
            if choice is None:
                continue

            if def_process:
                default_process_func(choice, &proc_str)
                choice_proc = RF_StringWrapper(proc_str)
                ScorerContext.similarity(&choice_proc.string, c_score_cutoff, &score)
            elif processor is not None:
                proc_choice = processor(choice)
                if proc_choice is None:
                    continue

                choice_proc = RF_StringWrapper(conv_sequence(proc_choice))
                ScorerContext.similarity(&choice_proc.string, c_score_cutoff, &score)
            else:
                choice_proc = RF_StringWrapper(conv_sequence(choice))
                ScorerContext.similarity(&choice_proc.string, c_score_cutoff, &score)

            if score >= score_cutoff:
                yield (choice, score, choice_key)

    def extract_iter_list():
        """
        implementation of extract_iter for:
          - type of choices = list
          - scorer = normalized scorer implemented in C++
        """
        cdef size_t i
        cdef double score

        for i, choice in enumerate(choices):
            if choice is None:
                continue

            if def_process:
                default_process_func(choice, &proc_str)
                choice_proc = RF_StringWrapper(proc_str)
                ScorerContext.similarity(&choice_proc.string, c_score_cutoff, &score)
            elif processor is not None:
                proc_choice = processor(choice)
                if proc_choice is None:
                    continue

                choice_proc = RF_StringWrapper(conv_sequence(proc_choice))
                ScorerContext.similarity(&choice_proc.string, c_score_cutoff, &score)
            else:
                choice_proc = RF_StringWrapper(conv_sequence(choice))
                ScorerContext.similarity(&choice_proc.string, c_score_cutoff, &score)

            if score >= c_score_cutoff:
                yield (choice, score, i)

    def extract_iter_distance_dict():
        """
        implementation of extract_iter for:
          - type of choices = dict
          - scorer = distance implemented in C++
        """
        cdef size_t distance

        for choice_key, choice in choices.items():
            if choice is None:
                continue

            if def_process:
                default_process_func(choice, &proc_str)
                choice_proc = RF_StringWrapper(proc_str)
                DistanceContext.distance(&choice_proc.string, c_max, &distance)
            elif processor is not None:
                proc_choice = processor(choice)
                if proc_choice is None:
                    continue

                choice_proc = RF_StringWrapper(conv_sequence(proc_choice))
                DistanceContext.distance(&choice_proc.string, c_max, &distance)
            else:
                choice_proc = RF_StringWrapper(conv_sequence(choice))
                DistanceContext.distance(&choice_proc.string, c_max, &distance)

            if distance <= c_max:
                yield (choice, distance, choice_key)

    def extract_iter_distance_list():
        """
        implementation of extract_iter for:
          - type of choices = list
          - scorer = distance implemented in C++
        """
        cdef size_t i
        cdef size_t distance

        for i, choice in enumerate(choices):
            if choice is None:
                continue

            if def_process:
                default_process_func(choice, &proc_str)
                choice_proc = RF_StringWrapper(proc_str)
                DistanceContext.distance(&choice_proc.string, c_max, &distance)
            elif processor is not None:
                proc_choice = processor(choice)
                if proc_choice is None:
                    continue

                choice_proc = RF_StringWrapper(conv_sequence(proc_choice))
                DistanceContext.distance(&choice_proc.string, c_max, &distance)
            else:
                choice_proc = RF_StringWrapper(conv_sequence(choice))
                DistanceContext.distance(&choice_proc.string, c_max, &distance)

            if distance <= c_max:
                yield (choice, distance, i)

    def py_extract_iter_dict():
        """
        implementation of extract_iter for:
          - type of choices = dict
          - scorer = python function
        """
        for choice_key, choice in choices.items():
            if choice is None:
                continue

            if processor is not None:
                score = scorer(query, processor(choice), **kwargs)
            else:
                score = scorer(query, choice, **kwargs)

            if score >= c_score_cutoff:
                yield (choice, score, choice_key)

    def py_extract_iter_list():
        """
        implementation of extract_iter for:
          - type of choices = list
          - scorer = python function
        """
        cdef size_t i

        for i, choice in enumerate(choices):
            if choice is None:
                continue

            if processor is not None:
                score = scorer(query, processor(choice), **kwargs)
            else:
                score = scorer(query, choice, **kwargs)

            if score >= c_score_cutoff:
                yield(choice, score, i)

    if query is None:
        # finish generator
        return

    if not processor:
        processor = None

    # preprocess the query
    if callable(processor):
        query = processor(query)
    elif processor:
        query = default_process(query)
        processor = default_process

    if processor is default_process:
        def_process = 1

    scorer_capsule = getattr(scorer, '_RF_Scorer', scorer)
    if PyCapsule_IsValid(scorer_capsule, NULL):
        scorer_context = <RF_Scorer*>PyCapsule_GetPointer(scorer_capsule, NULL)
        kwargs_context = KwargsInit(dereference(scorer_context), kwargs)

    if scorer_context and scorer_context.scorer_type == RF_SIMILARITY:
        query_context = RF_StringWrapper(conv_sequence(query))
        scorer_context.scorer.similarity_init(&similarity_context, &kwargs_context.kwargs, 1, &query_context.string)
        ScorerContext = RF_SimilarityWrapper(similarity_context)
        if score_cutoff is not None:
            c_score_cutoff = score_cutoff
        if c_score_cutoff < 0 or c_score_cutoff > 100:
            raise TypeError("score_cutoff has to be in the range of 0.0 - 100.0")

        if hasattr(choices, "items"):
            yield from extract_iter_dict()
        else:
            yield from extract_iter_list()
        # finish generator
        return

    if scorer_context and scorer_context.scorer_type == RF_DISTANCE:
        query_context = RF_StringWrapper(conv_sequence(query))
        scorer_context.scorer.distance_init(&distance_context, &kwargs_context.kwargs, 1, &query_context.string)
        DistanceContext = RF_DistanceWrapper(distance_context)
        if score_cutoff is not None and score_cutoff != -1:
            c_max = score_cutoff

        if hasattr(choices, "items"):
            yield from extract_iter_distance_dict()
        else:
            yield from extract_iter_distance_list()
        # finish generator
        return

    # the scorer has to be called through Python
    if score_cutoff is not None:
        c_score_cutoff = score_cutoff

    kwargs["processor"] = None
    kwargs["score_cutoff"] = c_score_cutoff

    if hasattr(choices, "items"):
        yield from py_extract_iter_dict()
    else:
        yield from py_extract_iter_list()

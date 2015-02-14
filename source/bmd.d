#!/usr/bin/env rdmd

import std.conv;
import std.json;
import std.stdio;
import std.getopt;
import std.algorithm;
import tinyredis.redis;
import painlessjson;

immutable string VERSION = "0.0.1";
immutable string HELP    =
"Simple command line browser independant bookmark utility.

Usage: bm [options] [-r] URL TAG...
       bm [options]  -d  URL
       bm [options]  -l  [TAG]...
       bm [options]  URL

Arguments:
    URL     The url to bookmark
            If alone, print the tags associated with URL
            If the url corresponds to an existing file,
            the absolute path is substituted to URL
            If URL is '-', then the program looks for a list of URL
            comming from the standard input.
    TAG     The tags to use with the url.

Options:
    -h, --help          Print this help and exit
    --version           Print current version number

    -r, --remove        Remove TAG from URL
    -d, --delete        Delete an url from the database
    -l, --list-every    List the urls with every of TAG
    -L, --list-any      List the urls with any of TAG

    -I, --redis-ID ID   Redis variable ID to be used
                        Default is BMD_DATA
";


class Database
{
    Redis            redis;
    string           redisID;
    string[][string] data;

    this(const string redisID,
         const string rHost="127.0.0.1",
         const ushort rPort=6379)
    {
        this.redisID = redisID;
        this.redis   = new Redis(rHost, rPort);
    }

    /***** Operator overloading to transfer access to this.data ******/

    @safe
    string[] opIndex(string idx)
    {
        return data[idx];
    }

    @safe
    void opIndexAssign(string[] value, const string idx)
    {
        data[idx] = value;
    }

    @safe
    pure
    string[]* opBinaryRight(string op)(const string value)
    {
        if (op == "in")
            return value in data;
    }

    /***** Redis interface *****/

    void getData()
    {
        string raw;

        if (!redis.send("EXISTS", redisID)) {
            redis.send("SET", redisID, "{}");
            raw = "{}";
        }
        else {
            raw = redis.send("GET", redisID).to!string;
        }

        debug writeln("* getData: " ~ raw);
        foreach(string url, JSONValue tags ; raw.parseJSON.object) {
            foreach(JSONValue tag ; tags.array) {
                data[url] ~= tag.str;
            }
        }
    }

    void setData()
    {
        redis.send("SET", redisID, data.toJSON);
    }

    /***** Data management *****/

    @safe
    void urlDelete(const string url)
    {
        if (url in data)
            data.remove(url);
    }

    @safe
    void tagAdd(const string url, const string tag)
    {
        if (tag) {
            if (url !in data)
                data[url] = [];
            data[url] ~= canFind(data[url], tag) ? [] : [tag];
        }
    }

    @safe
    void tagRemove(const string url, const string tag)
    {
        data[url] = data[url].splitter(tag).join();

        if (data[url].length == 0)
            this.urlDelete(url);
    }

    void tagsPrint(const string url)
    {
        if (url in data)
            foreach(tag ; data[url])
                writeln(tag);
    }

    @safe
    pure
    string[] listAny(const string[] tags)
    {
        string[] result = [];
        foreach (tag ; tags) {
            foreach(url, utag ; data)
                if (utag.canFind(tag))
                    result ~= url;
        }
        return result;
    }

    @safe
    pure
    string[] listEvery(const string[] tags)
    {
        string[] result = [];
        foreach (url, utag ; data) {
            bool canAdd = true;
            foreach (tag ; tags)
                if (!utag.canFind(tag))
                    canAdd = false;

            if (canAdd)
                result ~= url;
        }
        return result;
    }
}


int main(string[] args)
{
    bool optRemove    = false;
    bool optDelete    = false;
    bool optListAny   = false;
    bool optListEvery = false;
    auto ID           = "BMD_DATA";

    if (args.length == 1) {
        writeln(HELP);
        return 1;
    }

    getopt(args,
            "h|help",       { writeln(HELP); },
            "version",      { writeln("bmd version: " ~ VERSION); },
            "r|remove",     &optRemove,
            "l|list-every", &optListEvery,
            "L|list-any",   &optListAny,
            "d|delete",     &optDelete,
            "I|redis-ID",   &ID,
          );

    debug writeln("* Found ID=" ~ ID);
    debug ID = "DBG_BMD_DATA";
    debug writeln("* Set   ID=" ~ ID);

    auto url   = args.length>1 ? args[1]    : null;
    auto tags  = args.length>1 ? args[2..$] : null;

    auto db = new Database(ID);
    db.getData();

    debug writeln("* Original db: " ~ db.to!string);

    if (url in db && optDelete) {
        db.urlDelete(url);
    }
    else if (optRemove && url in db && tags.length != 0) {
        foreach(tag ; tags)
            db.tagRemove(url, tag);
    }
    else if (optListEvery || optListAny) {
        if (!url)
            foreach (u, t ; db.data)
                writeln(u);

        else {
            string[] delegate(const string[] tag) listFunction;

            if (optListEvery)
                listFunction = &db.listEvery;

            if (optListAny)
                listFunction = &db.listAny;

            tags = url ~ tags;
            foreach (elem ; listFunction(tags))
                writeln(elem);
        }
    }
    else if (tags.length != 0) {
        foreach(tag ; tags)
            db.tagAdd(url, tag);
    }
    else if (url in db) {
        db.tagsPrint(url);
    }

    debug writeln("* Final db: " ~ db.to!string);

    db.setData();
    return 0;
}
